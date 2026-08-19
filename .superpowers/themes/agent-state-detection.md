# Theme: Agent State Detection (CasperGhostty + CasperCore + CasperUI)

**Modules:** CasperGhostty, CasperCore, CasperUI · **Status:** ◐ built —
detection (working/blocked/idle) is live and verified, and `blocked`/`done`
transitions now raise notifications (see "Notifications"); the process-exit
`done`/`error` path is **not** implemented (unsupported by the embedded
libghostty — see "Process lifecycle") · **Code:** `Sources/CasperGhostty/`,
`Sources/CasperCore/`, `Sources/CasperUI/`

Infer each workspace's agent state (working / blocked / idle / done / unknown /
error) by reading the terminal itself, with **zero cooperation required from the
agent** — no hook installation, no CLI call. This complements the explicit
`casper status set` path (see `cli-agents.md`), which stays authoritative
whenever the agent uses it.

## Goal

Casper already carries `Workspace.agentState`, but today it only changes when
an agent explicitly calls `casper status set …`. An agent that never reports
leaves the workspace stuck at its default. This theme adds a second, implicit
producer of `agentState`: Casper owns the surface and its PTY, so it can read
the visible terminal grid and infer what the agent is doing. The whole consumer
side (the transient `agentState` field, the sidebar, later `UserNotifications`)
is reused unchanged — this theme only adds the detection source.

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

This revises the enum recorded in `architecture.md` (`idle | running | waiting |
done | error`): `running` becomes `working`, `waiting` becomes `blocked`,
`unknown` is promoted to a real case, and `error` is kept. The field stays
**transient** — not persisted, resets on load — exactly like today (`core.md`,
`SessionStore`).

| State | Meaning | Producer |
| --- | --- | --- |
| `working` | executing | detection (OSC title spinner) |
| `blocked` | waiting on the user | detection (viewport) |
| `idle` | at rest, seen | detection (OSC title / viewport) |
| `done` | at rest, unseen | derived (see resolver) |
| `error` | abnormal exit | `.childExited(exitCode: ≠0)` |
| `unknown` | no signal | resolver default |

## Detection

### Reading the terminal

Detection reads **two** signals per surface, both cheap and synchronous on the
main thread:

1. **The OSC title** — `GhosttySurfaceView.readOSCTitle()`. libghostty delivers
   the terminal title via `GHOSTTY_ACTION_SET_TITLE`; the runtime captures it
   per-surface (see Wiring) and the detector reads the latest value. This is the
   **primary `working` signal**: current Claude Code no longer prints an
   interrupt hint in the grid — it encodes its live state in the title (an
   animated Braille spinner while working, a `✳` at rest). The embedded
   libghostty fork forwards these title sequences intact (verified).
2. **The viewport grid** — `GhosttySurface.readText(scrollback: false)`
   fabricates a full-**viewport** selection and calls `ghostty_surface_read_text`.
   Read the **viewport only**, never the full scrollback, on every tick: the
   `blocked` affordances we match are always on the visible screen, and scraping
   scrollback each time is needlessly expensive.

Both `readText` (viewport) and `readOSCTitle` are exposed through **non-DEBUG
accessors** on `GhosttySurfaceView` / `AppModel` (`readViewportText()` /
`surfaceViewportText`, `readOSCTitle()` / `surfaceOSCTitle`) so the detector can
reach them in a release build (distinct from the `#if DEBUG` debug channel,
`themes/debug.md`).

### Trigger

Re-read on a coalesced "screen changed" signal rather than a busy poll.
`GHOSTTY_ACTION_RENDER` is already decoded as `GhosttyAction.render` (and, being
display-link driven, already fires — see `terminal.md`), but the runtime
currently discards it. Observe it, **throttled** (~150–300 ms), to schedule a
re-read. A plain timer poll is an acceptable fallback for a first cut.

Caveat: the action dispatch (`casperGhosttyAction`) only resolves the target
surface for the mouse actions today; extend that resolution (as done for
`MOUSE_SHAPE`) so a `render` tells us **which** surface changed.

### Rules

A small, **data-driven** matcher (`AgentDetectionRuleSet`) yields a raw signal
from each source. The patterns describe Claude Code's affordances and are held
as values on the rule set (not hard-coded control flow) so a new agent is just a
new rule set; the aspiration is to move them to an external, updatable resource
so they can track the agent's UI without a recompile. Viewport matching is
case-insensitive.

- **`working`** — from the **OSC title**: a leading **Braille spinner glyph**
  (any scalar in `U+2800…U+28FF`), the animated marker Claude Code shows while a
  turn is running. This is the authoritative "is it working" signal; its
  disappearance (the title reverting to a `✳` or to the shell's own cwd/command
  title) is the "no longer working" signal. The legacy viewport interrupt hints
  (`esc to interrupt`, `press esc to interrupt`, `ctrl+c to interrupt`) are
  **retained as a secondary matcher** for resilience and other agents, but
  current Claude Code no longer prints them.
- **`idle`** — from the **OSC title**: a leading `✳` (`U+2733`), the marker
  Claude Code shows at rest. A title with neither prefix (the shell's own
  cwd/command title) yields no title signal (`absent`), and the viewport's
  at-rest prompt then resolves to `idle`.
- **`blocked`** — from the **viewport**: a pending confirmation the agent shows
  only while it waits for the user — `do you want to proceed?` together with an
  `esc to cancel` affordance (and sibling confirmation prompts). `blocked`
  outranks a lingering `working` title in aggregation, so a pending prompt is
  never masked by a stale spinner.

### Resolver

The raw signal becomes the reported state through a small resolver — the only
place with policy; there is still no state machine on the model (`core.md`):

1. **No foreground agent → `unknown`.** The resolver maps the `absent` signal
   to `unknown`. **As built, the tick never feeds `absent`**: a workspace with
   no readable terminal this tick is *skipped* (its prior state is left
   untouched) rather than forced to `unknown`, so an unvisited workspace is not
   clobbered. So in the live wiring `unknown` (and `AgentSignal.absent`) come
   only from an explicit `casper status set unknown` and the unit tests; the
   `absent → unknown` mapping is retained for when a real liveness signal is
   wired.
2. **Debounce transitions.** Require the `working` affordance to be **absent for
   N consecutive reads** before `working → idle`, so a gap between two tool
   calls does not flicker to idle. Never let a late or stale read revive `idle`
   once a terminal state has been set.
3. **Priority (multi-signal / aggregation):**
   `blocked` > `working` > `done` > `idle` > `unknown`.
4. **`done` is derived, not matched.** A `working → idle` transition while the
   workspace is **unseen** presents as `done`; it collapses to `idle` once seen
   (`focusedSurfaceID` / `selectedWorkspaceID` point at it). `done` is the
   pre-notification attention state.

## Authority: explicit CLI vs detection

Explicit reporting and detection must not fight. A per-workspace, **transient**
latch decides who owns the state:

```swift
enum AgentAuthority: Sendable { case detection, explicit }
```

- Default `detection` — the scraper drives `agentState`.
- The moment `casper status set …` lands for a workspace W
  (`AppModel.controlSetAgentState`), authority flips to `explicit` and **PTY
  detection stops for W**: the scraper is no longer *scheduled* for W's
  surfaces (not merely suppressed after the fact). The explicit value is
  authoritative.
- The latch is **not persisted** — it resets to `detection` on load, like the
  agent state it guards.

Rationale: an agent that reports its own state is more precise than any scrape;
once it opts in, detection steps aside.

**In practice, this is permanent for any `casper-claude-plugin`-driven
workspace.** `hooks/user-prompt-submit.sh` and `hooks/pre-tool-use.sh` call
`casper status set working` on the very first Claude Code turn, which grants
explicit authority immediately — and since authority release isn't
implemented (see Deferred), the scraper never runs again for that workspace
for the rest of the session. Its `working → idle (unseen) → done` derivation
(Resolver, point 4) therefore never fires for a hook-driven workspace; only
an explicit `casper status set done` can produce `done` for it. See
`plans/stop-hook-explicit-done.md` for the consequence (the `Stop` hook must
report `done` itself) and the matching explicit-authority `done → idle`
collapse on selection (next section).

### Explicit-authority `done` → `idle` collapse (on selection)

The resolver's own seen-gated unlatch (point 4 above) only runs inside
`runAgentDetectionTick`, which is skipped entirely for a workspace under
explicit authority. So for a hook-driven workspace, nothing ever collapses
an explicit `done` back to `idle` on its own — `AppModel.selectWorkspace`
does it explicitly instead: selecting a workspace whose `agentState == .done`
sets it to `.idle`, mirroring the resolver's own "seen" definition
(`selectedWorkspaceID` pointing at it — not gated on `isWindowKey()`, unlike
the sibling bubble-clear in `clearNotificationForFocusedWorkspace()`). Only
`done` collapses this way; `blocked`/`error` are untouched by selection in
either the detected or explicit path. See `plans/stop-hook-explicit-done.md`.

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
fix (`terminal new --command`) now runs reliably, but deliberately via
`ghostty_surface_config_s.initial_input` typed as plain text — not `exec`'d,
and not using `command` at all — so it does not replace the shell process.
Agents therefore still always run **inside a shell** (the user types `claude`,
or `--command claude` types it for them); the shell survives when the agent
exits, and no agent-scoped exit event is available. See the CasperGhostty note
in `themes/cli-agents.md`.

Given the shell-hosted reality:
- **`done`** is still produced by the resolver's own `working → idle` derivation
  (the agent finishes, the shell shows the completed output at rest, unseen →
  `done`). No process-exit hook needed.
- **`error`** has no detected producer for now; a crashed agent reads as `idle`
  from its at-rest shell. Acceptable until there's a real signal for it.
- **Authority release** (undoing a `casper status set` latch) is likewise
  deferred: there is no reliable per-agent exit event, so a workspace that took
  explicit authority stays latched until reload. Robust release will come with
  the **timeout mechanism (option B)** wired alongside `casper notify`.

## Aggregation (per-workspace)

`agentState` stays **per-workspace**; a workspace can hold several terminal
panes. The detector rolls the per-surface raw signals up to the **most urgent**
using the resolver priority above. Which surfaces feed the rollup: **every
terminal surface** of the workspace — detection is text-based, so it works
regardless of how the terminal was launched (an agent run inside any shell is
matched all the same). **No `Surface.status` field is added** in v1 — detection
state lives only at the workspace level.

## Wiring (as built)

- **CasperGhostty** — non-DEBUG `readViewportText()` accessor **and**
  `readOSCTitle()`: `casperGhosttyAction` captures `GHOSTTY_ACTION_SET_TITLE`
  per-surface (resolving the target the same way it does for `MOUSE_SHAPE`) into
  `GhosttySurfaceView.latestOSCTitle`, then falls through so the app-level
  window-title behavior is preserved. (A `.render`-driven trigger is deferred;
  see Deferred.)
- **CasperCore** — the revised `AgentState` and the pure engine
  (`AgentDetection.swift`): both `signal(fromViewport:)` and `signal(fromTitle:)`,
  the latter classifying the Braille-spinner / `✳` title prefixes.
- **CasperUI** — a detector owned by `AppModel` (main actor): a ~250 ms timer
  scrapes each workspace's terminals — viewport **and** OSC title — aggregates
  the two signals, runs the resolver, and writes `agentState` via
  `setDetectedAgentState` unless the workspace is under explicit authority.
  The authority latch is set in `controlSetAgentState` (`casper status set`);
  its release is deferred (option B). The sidebar status icon lives on
  `WorkspaceRow` (monochrome outline SF Symbols in the chevron column, animated
  `working`).

### Notifications

`setDetectedAgentState` raises a notification on a transition into an attention
state — `blocked` → `"Waiting for your input"`, `done` → `"Task finished"` — by
calling `controlRaiseNotification(message:for:)`, the same mechanism `casper
notify` uses. This is what makes notification + sidebar-dot support work **with
no Claude Code hook**: it is driven purely by Casper's own OSC/viewport scraping
rather than an explicit CLI call. The write is edge-triggered (the "only on
change" guard), so a steady detection stream notifies once per transition, and
`controlRaiseNotification`'s focus semantics still apply (the dot is suppressed
for a focused workspace, but the macOS notification is always delivered).

`controlSetAgentState` (the explicit CLI path) mirrors this for `.done`
only — an explicit `casper status set done` also raises the bubble +
passive notification, since a hook-driven workspace can never reach `done`
through detection (see Authority above). It deliberately does **not** do
the same for `blocked`/`error`: both already get an explicit `casper notify`
from their own callers (`hooks/notification.py`, the `casper-status`
skill), so mirroring `setDetectedAgentState` there would double the
notification. See `plans/stop-hook-explicit-done.md`.

## Deferred / out of scope

- **`.render`-driven trigger** — replace the ~250 ms timer poll with a
  throttled re-read on `GHOSTTY_ACTION_RENDER` (decoded as `.render`, currently
  discarded).
- **Timeout-based authority release** for shell-hosted agents (option B),
  wired with `casper notify`.
- **A real `error` signal** and the **agent-as-command** `done`/`error` path —
  the `--command` reliability fix shipped (see "Process lifecycle"), but
  deliberately without `exec` semantics, so it does not itself create an
  agent-as-command surface; re-evaluating that path is a separate, unscoped
  project.
- **Per-surface status** field + pane-chrome indicator (option B).
- **Agents beyond Claude Code** — the rule set is per-agent.

## Open questions

- Which surfaces feed the workspace rollup when more than one agent runs in a
  workspace.
- Exact debounce count N and throttle interval — tuned live.
- Whether the rule set ships as an in-repo resource or is fetched/updatable.
