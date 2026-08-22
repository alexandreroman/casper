# Theme: Agent State Detection (CasperGhostty + CasperCore + CasperUI)

**Modules:** CasperGhostty, CasperCore, CasperUI · **Status:** ◐ built —
detection (working/blocked/idle) is live and verified, and `blocked`/`done`
transitions now raise notifications (see "Notifications"); the process-exit
`done`/`error` path is **not** implemented (by decision, not for lack of support
— see "Process lifecycle") · **Code:** `Sources/CasperGhostty/`,
`Sources/CasperCore/`, `Sources/CasperUI/`

Infer each workspace's agent state (working / blocked / idle / done / unknown /
error) by reading the terminal itself, with **zero cooperation required from the
agent** — no hook installation, no CLI call. This complements the explicit
`casper status set` path (see `cli-agents.md`), which stays authoritative
whenever the agent uses it.

## Goal

Casper already carries `Workspace.agentState`, but today it only changes when an
agent explicitly calls `casper status set …`. An agent that never reports leaves
the workspace stuck at its default. This theme adds a second, implicit producer
of `agentState`: Casper owns the surface and its PTY, so it can read the visible
terminal grid and infer what the agent is doing. The whole consumer side (the
transient `agentState` field, the sidebar, later `UserNotifications`) is reused
unchanged — this theme only adds the detection source.

## Model: `AgentState`

Detection drives a revised `AgentState` enum (CasperCore `Models.swift`):

```swift
public enum AgentState: String, Codable, Sendable {
    case working    // agent is actively executing
    case blocked    // agent is waiting for the user (a prompt is pending)
    case idle       // at rest, and the user has seen it
    case done       // at rest, finished, not yet seen (attention)
    case unknown    // no agent at the foreground / nothing readable
    case error      // agent exited abnormally
}
```

This is the same enum `architecture.md` records. The field is **transient** —
not persisted, reset on load — like the rest of the agent-facing runtime state
(`core.md`, `SessionStore`).

| State     | Meaning                        | Producer                                  |
| --------- | ------------------------------ | ----------------------------------------- |
| `working` | executing                      | detection (OSC 9;4 progress report)       |
| `blocked` | waiting on the user            | detection (viewport)                      |
| `idle`    | at rest, seen                  | detection (OSC title / viewport)          |
| `done`    | at rest, unseen                | derived (see resolver)                    |
| `error`   | a `setup` hook exited non-zero | `ScriptHookRunner` → `reportSetupFailure` |
| `unknown` | no signal                      | resolver default                          |

## Detection

### Reading the terminal

Detection reads **three** signals per surface, all cheap and synchronous on the
main thread:

1. **The OSC 9;4 progress report** — `GhosttySurfaceView.readProgressReport()`.
   This is the **primary `working` signal**. Claude Code emits ConEmu/iTerm2
   progress reports around every turn, libghostty decodes them into
   `GHOSTTY_ACTION_PROGRESS_REPORT`, and the runtime latches the state
   per-surface (see Wiring). Verified against a real Claude Code 2.1.239 PTY
   capture: `ESC]9;4;0` when the REPL starts, `ESC]9;4;3` (indeterminate) for
   the whole duration of a turn, `ESC]9;4;0` again when the turn ends. Claude
   Code gates the emission on the terminal advertising support — inside a Casper
   terminal `TERM_PROGRAM=ghostty` and `TERM_PROGRAM_VERSION=1.3.1`, clearing
   its `>= 1.2.0` bar — and on the `terminalProgressBarEnabled` setting, which
   defaults on.
2. **The OSC title** — `GhosttySurfaceView.readOSCTitle()`. libghostty delivers
   the terminal title via `GHOSTTY_ACTION_SET_TITLE`; the runtime captures it
   per-surface and the detector reads the latest value. A **secondary** signal:
   Claude Code still encodes its state in the title (an animated spinner while
   working, a `✳` at rest), but the spinner glyph is not stable across
   releases — 2.1.239 prints the quadrant circles `◐◑◒◓` (U+25D0–U+25D3) where
   earlier builds printed Braille (U+2800–U+28FF), so both ranges are matched
   and neither is trusted as the sole liveness signal.
3. **The viewport grid** — `GhosttySurface.readText(scrollback: false)`
   fabricates a full-**viewport** selection and calls
   `ghostty_surface_read_text`. Read the **viewport only**, never the full
   scrollback, on every tick: the `blocked` affordances we match are always on
   the visible screen, and scraping scrollback each time is needlessly
   expensive. This is the only source for `blocked`, and the only `working`
   source for agents that report no progress (Codex, opencode).

`readText` (viewport), `readOSCTitle` and `readProgressReport` are all exposed
through **non-DEBUG accessors** on `GhosttySurfaceView` / `AppModel`
(`readViewportText()` / `surfaceViewportText`, `readOSCTitle()` /
`surfaceOSCTitle`, `readProgressReport()` / `surfaceProgressReport`) so the
detector can reach them in a release build (distinct from the `#if DEBUG` debug
channel, `themes/debug.md`).

### Trigger

Re-read on a coalesced "screen changed" signal rather than a busy poll.
`GHOSTTY_ACTION_RENDER` is already decoded as `GhosttyAction.render` (and, being
display-link driven, already fires — see `terminal.md`), but the runtime
currently discards it. Observe it, **throttled** (~150–300 ms), to schedule a
re-read. A plain timer poll is an acceptable fallback for a first cut.

Caveat: `GHOSTTY_ACTION_RENDER` is still handled app-wide. The action dispatch
(`casperGhosttyAction`) already resolves the target surface from the per-surface
`userdata` for five actions — `MOUSE_SHAPE`, `MOUSE_VISIBILITY`, `SET_TITLE`,
`PROGRESS_REPORT` and `SHOW_CHILD_EXITED` — each of which terminates there
rather than flowing on to the app-level `onAction`. Extending the same
resolution to `render` is what would tell us **which** surface changed.

### Rules

A small, **data-driven** matcher (`AgentDetectionRuleSet`) yields a raw signal
from the two text sources; the progress report needs no patterns and maps
straight through `AgentSignal(progress:)`. The patterns are held as values on
the rule set (not hard-coded control flow) so a new agent is just a new rule
set; the aspiration is to move them to an external, updatable resource so they
can track the agent's UI without a recompile. Viewport matching is
case-insensitive.

Three rule sets exist — `claudeCode`, `codex` and `opencode` — and
`AgentDetectionRuleSet.all` collects them. Detection has no way to know *which*
agent occupies a surface, so it applies **all** of them to the same snapshot and
aggregates the signals rather than selecting one; each rule set's needles are
specific enough to stay quiet on another agent's screen. The rules below name
the agent each pattern was measured against.

- **`working`** — primarily from the **OSC 9;4 progress report**: `SET`
  (`9;4;1`, a determinate bar) and `INDETERMINATE` (`9;4;3`, what Claude Code
  emits for a whole turn) both mean an operation is running. `REMOVE` (`9;4;0`)
  maps to `absent`, not `idle` — "this source says nothing" — so a shell that
  never reports progress stays indistinguishable from an agent that just
  finished, and the other two sources still decide. `ERROR` (`9;4;2`) and
  `PAUSE` (`9;4;4`) also map to `absent`: an error bar records the outcome of
  finished work rather than liveness and lingers until the next report, and no
  agent Casper targets emits `PAUSE` at all — pinning the workspace to a state
  on either would be a guess. Secondarily from the **OSC title**: a leading
  spinner glyph, matched over **two** disjoint ranges — the quadrant circles
  `◐◑◒◓` (U+25D0–U+25D3) that Claude Code 2.1.239 prints, and Braille
  (U+2800–U+28FF) as printed by earlier builds and kept for other agents. The
  legacy viewport interrupt hints (`esc to interrupt`, `ctrl+c to interrupt`)
  are **retained as a third matcher** for Codex and for resilience; current
  Claude Code no longer prints them anywhere a running turn can be seen.
  opencode needs a needle of its own, `esc interrupt` (no "to"), which is the
  only source that sees an opencode turn at all.
- **`idle`** — from the **OSC title**: a leading `✳` (`U+2733`), the marker
  Claude Code shows at rest (still emitted by 2.1.239, verified). A title with
  no recognised prefix (the shell's own cwd/command title) yields no title
  signal (`absent`), and the viewport's at-rest prompt then resolves to `idle`.
- **`blocked`** — from the **viewport**: a pending confirmation the agent shows
  only while it waits for the user — `do you want to proceed?` together with an
  `esc to cancel` affordance (and sibling confirmation prompts), or opencode's
  `Permission required` together with an `Allow once` choice. Two substrings
  are required in each group so a chat message quoting either phrase alone
  cannot trip it. `blocked` outranks a `working` progress report in
  aggregation, so a pending prompt is never masked by a progress bar the agent
  left up — nor by opencode's interrupt footer, which stays on screen
  underneath its permission prompt.

#### Why the progress report and not the title or the viewport

Both of the older signals were the primary once and both decayed, which is the
reason liveness now rests on a protocol Claude Code emits deliberately rather
than on its UI chrome:

- **The viewport interrupt hint is gone.** `esc to interrupt` still exists in
  the 2.1.239 bundle, but at exactly one call site: the `low_priority_waiting`
  API-retry banner (`· next try in … · attempt … · esc to interrupt`). It is
  never rendered during normal work — a full PTY capture of a turn contains no
  occurrence of it — so `signal(fromViewport:)` falls through to `idle` for the
  entire run.
- **The title spinner is unstable.** It is still emitted, but the glyph changed
  under us (Braille → quadrant circles), and the title is otherwise plain
  stripped text. Matching a moving glyph set is a maintenance treadmill; it
  stays as a fallback, not as the thing the sidebar spinner depends on.
- **OSC 21337 (`TAB_STATUS`) is a dead end.** Claude Code carries a structured
  status protocol with exactly the right payload
  (`{idle:{status:"Idle"}, busy:{status:"Working…"},
  waiting:{status:"Waiting"}}`), but it is feature-flagged off — the gate
  function returns `false` unconditionally and the emitter early-returns, so
  nothing is ever written.
  The vendored libghostty header does not decode OSC 21337 either.

By contrast OSC 9;4 is a user-visible product feature
(`terminalProgressBarEnabled`, "Emit OSC 9;4 progress sequences during long
operations"), it is already modelled by the pinned libghostty header
(`ghostty_action_progress_report_s`) — so this theme needed no `make vendor`
bump — and it is emitted by iTerm2/ConEmu-aware tools generally, so it degrades
into a signal other long-running commands share rather than into nothing.

### What each agent actually emits

Detection is version-coupled to each agent's terminal UI, so the table below
records what was **measured**, not what was assumed — captured by running the
agent under `script -q` with `TERM_PROGRAM=ghostty` and
`TERM_PROGRAM_VERSION=1.3.1` (the values a Casper terminal sets) and grepping
the raw file for `ESC]9;4;` and `ESC]0;`. Re-run that capture before trusting
any row after an agent upgrade.

| Agent | OSC 9;4 progress | OSC title | Viewport affordance |
| ----- | ---------------- | --------- | ------------------- |
| Claude Code 2.1.239 | `9;4;3` for the whole turn, `9;4;0` at its end | `◐◑` while working, `✳` at rest | none |
| opencode 1.18.20 | none | plain ASCII (`OpenCode`, `OC \| <turn title>`) — never a glyph prefix | `esc interrupt` footer while a turn runs; `Permission required` + `Allow once`/`Reject` when blocked |
| codex-cli 0.149.0 | none (static: the binary contains no `9;4` and no `ConEmu`) | not measured | not measured |

Two consequences worth stating outright:

- **opencode's viewport is readable; its title and progress are not.** It emits
  no OSC 9;4 sequence at all and its title asserts nothing, so those two sources
  stay `absent`. The viewport does carry state: while a turn runs, the footer
  row reads
  `■⬝⬝⬝⬝⬝⬝⬝  esc interrupt … tab agents  ctrl+p commands`. Note the missing
  "to" — Claude Code's `esc to interrupt` needle does not match it, which is why
  opencode needs a rule set of its own. That row is written only while the turn
  runs and is overwritten by the at-rest footer (path + token count +
  `ctrl+p commands`) when it ends, verified against the raw byte stream, so the
  affordance does not latch. A pending permission prompt renders
  `Permission required` above `Allow once` / `Allow always` / `Reject` **while
  the interrupt footer is still on screen**, so `blocked` has to outrank
  `working` — it already does, both inside `signal(fromViewport:)` and in
  `AgentSignal.aggregate`. What the viewport cannot show still rests on the
  explicit CLI path (`casper status set …`, driven by the plugin's own hooks).
- **Adding a source that no agent owns changes every terminal, not just an
  agent's.** Any command that reports OSC 9;4 progress — a package manager, a
  download — now reads as `working` for its workspace. That is defensible
  ("something is running") and is the same generality that makes the signal
  worth depending on, but it is a behaviour change for plain shell panes too.

The codex row is static-only, and deliberately marked as such: the agent exits
immediately under `script` with a piped stdin, so no live capture was obtained.
The static claim is nonetheless sound for a **compiled Rust** binary, where a
string literal is stored as raw bytes with no `\uXXXX` indirection — emitting
`ESC]9;4;…` without `9;4` appearing anywhere would require building the
sequence character by character. (The same reasoning does **not** transfer to a
JavaScript bundle, where glyphs and escapes are stored as `\uXXXX` text and a
raw-byte grep proves nothing — the trap that produced the initial, incorrect
"the title spinner is gone" reading of Claude Code.)

### Resolver

The raw signal becomes the reported state through a small resolver — the only
place with policy; there is still no state machine on the model (`core.md`):

1. **No foreground agent → `unknown`.** The resolver maps the `absent` signal to
   `unknown`. **As built, the tick never feeds `absent`**: a workspace with no
   readable terminal this tick is *skipped* (its prior state is left untouched)
   rather than forced to `unknown`, so an unvisited workspace is not clobbered.
   So in the live wiring `unknown` (and `AgentSignal.absent`) come only from an
   explicit `casper status set unknown` and the unit tests; the
   `absent → unknown` mapping is retained for when a real liveness signal is
   wired.
2. **Debounce transitions.** Require the `working` affordance to be **absent for
   N consecutive reads** before `working → idle`, so a gap between two tool
   calls does not flicker to idle. Never let a late or stale read revive `idle`
   once a terminal state has been set.
3. **Priority (multi-signal / aggregation):** `blocked` > `working` > `done` >
   `idle` > `unknown`.
4. **`done` is derived, not matched.** A `working → idle` transition while the
   workspace is **unseen** presents as `done`; it collapses to `idle` once seen
   (`focusedSurfaceID` / `selectedWorkspaceID` point at it). `done` is the
   pre-notification attention state.

## Authority: explicit CLI vs detection

Explicit reporting and detection must not fight. A per-workspace, **transient**
latch decides who owns the state:

There is no `AgentAuthority` enum: the latch as built is a set of workspace ids,
`explicitAuthority: Set<UUID>` on `AppModel`, read through
`isUnderExplicitAuthority(_:)`. Membership means the workspace is under explicit
authority; absence means detection owns it.

- Default (not a member) — the scraper drives `agentState`.
- `working`, `idle`, and `unknown` **never** grant authority: they describe
  conditions the terminal itself can continuously observe, so an explicit report
  of one leaves detection in charge. That is what lets the viewport correct a
  stale hook-reported `working` — a `UserPromptSubmit` hook whose matching
  `Stop` hook never fires (Codex today) cannot strand a workspace.
- Only `blocked`, `done`, and `error` grant explicit authority, because a
  terminal scrape cannot safely *clear* an attention state. The `Stop` hook
  still reports `done` precisely; selecting that workspace then collapses the
  explicit `done` back to `idle` (next section).
- The latch is **not persisted** — it resets to `detection` on load, like the
  agent state it guards.

### Explicit-authority `done` → `idle` collapse (on selection)

An explicit `done` suppresses detection, so `AppModel.selectWorkspace` collapses
it to `.idle` when selected. This mirrors the resolver's own "seen" definition
(`selectedWorkspaceID` pointing at it — not gated on `isWindowKey()`, unlike the
sibling bubble-clear in `clearNotificationForFocusedWorkspace()`). Only `done`
collapses this way; `blocked` and `error` are untouched. See
`plans/stop-hook-explicit-done.md`.

## Process lifecycle: `done` / `error` — not implemented

`done` and `error` are in the `AgentState` model, but there is **no detected
producer** for them, by decision. The obvious source — a process-exit event
(`GHOSTTY_ACTION_SHOW_CHILD_EXITED`) mapping exit `0 → done` / `≠0 → error` —
was implemented and then **removed**, because it only makes sense for an
*agent-as-command* surface and that scenario does not exist in Casper today:

**`--command` does not create an agent-as-command surface.** It was believed
that the embedded libghostty simply didn't honor a surface's `command` at all;
that turned out to be wrong — the pinned fork (`libghostty-spm`, a
sandbox/host-managed-oriented fork) does run it, but via a hardcoded
`bash -l -c "exec <command>"` that ignored the user's real shell. The shipped
fix (`terminal new --command`) runs reliably, but deliberately types the text
into the already-spawned login shell via `ghostty_surface_text` — not `exec`'d,
and using neither the `command` nor the `initial_input` config field — so it
does not replace the shell process. See [[ghostty-initial-input-utf8]]. Agents
therefore still always run **inside a shell** (the user types `claude`, or
`--command claude` types it for them); the shell survives when the agent exits,
and no agent-scoped exit event is available. See the CasperGhostty note in
`themes/cli-agents.md`.

Given the shell-hosted reality:
- **`done`** is still produced by the resolver's own `working → idle` derivation
  (the agent finishes, the shell shows the completed output at rest, unseen →
  `done`). No process-exit hook needed.
- **`error`** has no *terminal-scraping* producer for now; a crashed agent reads
  as `idle` from its at-rest shell. It is still produced outside detection, by a
  `.casper.json` `setup` hook that exits non-zero (`ScriptHookRunner` →
  `AppModel.reportSetupFailure` → `setDetectedAgentState(.error, …)`).
  Acceptable until there's a real scraped signal for it.
- **Authority release** for terminal-observable states is immediate: the CLI
  removes their latch. `blocked`, `done`, and `error` remain authoritative until
  their state is explicitly changed or the app reloads.

## Aggregation (per-workspace)

`agentState` stays **per-workspace**; a workspace can hold several terminal
panes. The detector rolls the per-surface raw signals up to the **most urgent**
using the resolver priority above. Which surfaces feed the rollup: **every
terminal surface** of the workspace — detection is text-based, so it works
regardless of how the terminal was launched (an agent run inside any shell is
matched all the same). **No `Surface.status` field is added** in v1 — detection
state lives only at the workspace level.

## Wiring (as built)

- **CasperGhostty** — non-DEBUG `readViewportText()`, `readOSCTitle()` **and**
  `readProgressReport()` accessors: `casperGhosttyAction` captures
  `GHOSTTY_ACTION_SET_TITLE` and `GHOSTTY_ACTION_PROGRESS_REPORT` per-surface
  (resolving the target the same way it does for `MOUSE_SHAPE`) into
  `GhosttySurfaceView.latestOSCTitle` / `latestProgressReport`. Both cases
  terminate there — the target view is their only consumer — and both report the
  action as consumed even when no view is recoverable, matching the app-level
  `handleAction`. The pinned libghostty header already models the progress
  report (`ghostty_action_progress_report_s`), so this needed no `make vendor`
  bump and no fork change. (A `.render`-driven trigger is deferred; see
  Deferred.)
- **CasperCore** — the revised `AgentState` and the pure engine
  (`AgentDetection.swift`): `signal(fromViewport:)`, `signal(fromTitle:)`
  (classifying the spinner / `✳` title prefixes), and `AgentSignal(progress:)`
  over the CasperCore-level `AgentProgressState` — a one-for-one restatement of
  `ghostty_action_progress_report_state_e` so the C enum never reaches
  CasperCore, which must not depend on GhosttyKit.
- **CasperUI** — a detector owned by `AppModel` (main actor): a timer that ticks
  every ~250 ms while the window is visible and is throttled to ~1 s while it is
  hidden — it is never stopped (`agentDetectionIntervalVisible` /
  `agentDetectionIntervalHidden`) — scrapes each workspace's terminals,
  viewport, OSC title **and** OSC 9;4 progress state, evaluates the two text
  sources against **every** rule set in `AgentDetectionRuleSet.all`
  (`claudeCode`, `codex`, `opencode` — read once per surface and replayed
  across the rule sets, since nothing there knows which agent runs in the
  surface), aggregates all the signals, runs the resolver, and writes
  `agentState` via `setDetectedAgentState` unless the workspace is under
  explicit authority. `controlSetAgentState` latches only `blocked`, `done`, and
  `error`; it releases terminal-observable states immediately. The sidebar status
  icon lives on `WorkspaceRow` (monochrome outline SF Symbols in the chevron
  column, animated `working`).

### Notifications

`setDetectedAgentState` raises a notification on a transition into an attention
state — `blocked` → `"Waiting for your input"`, `done` → `"Task finished"` — by
calling `controlRaiseNotification(message:for:)`, the same mechanism `casper
notify` uses. This is what makes notification + sidebar-dot support work **with
no Claude Code hook**: it is driven purely by Casper's own OSC/viewport scraping
rather than an explicit CLI call. The write is edge-triggered (the "only on
change" guard), so a steady detection stream notifies once per transition, and
`controlRaiseNotification`'s focus semantics still apply: **a focused workspace
gets neither** — the same `!focused` guard covers the sidebar dot and the macOS
notification, so nothing is raised for the workspace the user is already looking
at.

That guard carries a second condition: a **per-workspace de-dup cooldown**.
`controlRaiseNotification` records `lastNotifiedAt[workspaceID]` on every
delivery and skips a repeat that falls within `notificationCooldown`
(`isWithinNotificationCooldown`). It exists because the explicit path and the
detection path can fire for the same event within milliseconds of each other —
an agent's `casper notify` landing just as the scraper resolves the same
transition — and the user should hear about that once. The cooldown gates the
notification only; the attention flag, the Dock badge and the Space auto-expand
are unaffected by it.

`controlSetAgentState` (the explicit CLI path) mirrors this for `.done` only —
an explicit `casper status set done` also raises the bubble + passive
notification. It deliberately does **not** do the same for
`blocked`/`error`: both already get an explicit `casper notify` from their own
callers (`hooks/notification.py`, the `casper-status` skill), so mirroring
`setDetectedAgentState` there would double the notification. See
`plans/stop-hook-explicit-done.md`.

Arming the bubble also drives the Dock icon — a bounce that runs until Casper is
activated, plus a badge counting the unread workspaces. Their exact clearing
rules live in `app-ui.md` § Design → "Dock attention".

## Deferred / out of scope

- **`.render`-driven trigger** — replace the timer poll (~250 ms while the
  window is visible, ~1 s while it is hidden) with a throttled re-read on
  `GHOSTTY_ACTION_RENDER` (decoded as `.render`, currently discarded).
- **Timeout-based authority release** for shell-hosted agents (option B), wired
  with `casper notify`.
- **A real `error` signal** and the **agent-as-command** `done`/`error` path —
  the `--command` reliability fix shipped (see "Process lifecycle"), but
  deliberately without `exec` semantics, so it does not itself create an
  agent-as-command surface; re-evaluating that path is a separate, unscoped
  project.
- **Per-surface status** field + pane-chrome indicator (option B).

### Codex native viewport detection

Codex has a native viewport rule set (`AgentDetectionRuleSet.codex`) alongside
Claude Code's. Its `esc to interrupt` / `ctrl+c to interrupt` affordance and
`Running tools` status identify live execution; Codex has no documented
OSC-title state, so its title is deliberately ignored (its
`titleWorkingScalars` is empty) and it publishes no OSC 9;4 progress, so the
viewport is its only source.

**Whether those affordances still exist is unverified** — see the open question
below. They are what the rule set was written against; nothing has confirmed
them against a current Codex build.

**It is reachable at runtime.** `runAgentDetectionTick` applies every rule set
in `AgentDetectionRuleSet.all` to the same snapshot and aggregates the
signals, so the `Running tools` needle now contributes. Selecting *one* rule
set per surface would need a way to know which agent runs there, which
detection does not have; the union sidesteps that, at the price of every
agent's needles being live on every terminal. The same union is what makes
opencode's `esc interrupt` footer and `Permission required` prompt reachable.
Explicit `working`, `idle`, and `unknown` updates remain observable by the
terminal detector. This prevents a
`UserPromptSubmit` hook from leaving a workspace stuck in `working` if its
separate `Stop` hook is not available. Explicit `blocked`, `done`, and `error`
remain authoritative because terminal text cannot safely clear those attention
states.

## Open questions

- **Does current Codex still print an interrupt affordance at all?** The
  viewport is Codex's only source, and the two hints the rule set matches
  (`esc to interrupt`, `ctrl+c to interrupt`) are exactly the ones Claude Code
  removed. If Codex dropped them too, Codex detection is dead in the same
  silent way — a workspace that reports `idle` for a whole turn, with nothing
  in the code to indicate a fault. Answering it needs a live capture, which the
  `script`-with-piped-stdin harness cannot produce for Codex (it exits at
  once); drive it from a real interactive terminal, or from a Casper terminal
  with `casper debug read-text`, and check the viewport mid-turn.
- Which surfaces feed the workspace rollup when more than one agent runs in a
  workspace.
- Exact debounce count N and throttle interval — tuned live.
- Whether the rule set ships as an in-repo resource or is fetched/updatable.
