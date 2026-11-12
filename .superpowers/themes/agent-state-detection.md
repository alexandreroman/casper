# Theme: Agent State Detection (CasperGhostty + CasperCore + CasperUI)

**Modules:** CasperGhostty, CasperCore, CasperUI · **Status:** ◐ built —
detection (working/blocked/idle) is live and verified, each terminal's
foreground process selects the agent's rule set and reads a shell prompt as "no
agent", an agent's exit resolves to `done` and can release the explicit latch,
and `blocked`/`done` transitions raise notifications (see "Notifications"); a
detected `error` is **not** implemented — the exit edge is seen, the exit code
is not (see "Process lifecycle") · **Code:** `Sources/CasperGhostty/`,
`Sources/CasperCore/`, `Sources/CasperUI/`

Infer each workspace's agent state (working / blocked / idle / done / unknown /
error) by reading the terminal itself, with **zero cooperation required from the
agent** — no hook installation, no CLI call. This complements the explicit
`casper status set` path (see `cli-agents.md`), which stays authoritative
whenever the agent uses it.

## Goal

`Workspace.agentState` has two producers. The first is an agent explicitly
calling `casper status set …`; an agent that never reports would leave the
workspace at its default. Detection is the second, implicit producer: Casper
owns the surface and its PTY, so it reads the visible terminal grid and infers
what the agent is doing. The consumer side — the transient `agentState` field,
the sidebar, the notifications — is shared by both producers; this theme covers
the detection source.

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

This is the same enum `../architecture.md` records. The field is **transient** —
not persisted, reset on load — like the rest of the agent-facing runtime state
(`core.md`, `SessionStore`).

| State     | Meaning                        | Producer                                  |
| --------- | ------------------------------ | ----------------------------------------- |
| `working` | executing                      | detection (OSC 9;4 progress report)       |
| `blocked` | waiting on the user            | detection (viewport)                      |
| `idle`    | at rest, seen                  | detection (OSC title / viewport)          |
| `done`    | at rest, unseen                | derived (see resolver)                    |
| `error`   | a `setup` hook exited non-zero | `ScriptHookRunner` → `reportSetupFailure` |
| `unknown` | no agent, or no signal         | detection (shell foreground) / default    |

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
   Code gates the emission on the terminal advertising support — a Casper
   terminal sets `TERM_PROGRAM=ghostty` and `TERM_PROGRAM_VERSION` to the
   linked libghostty's version, `1.4.1-HEAD+042b16b61` on the current pin (the
   2.1.239 capture ran under the earlier `1.3.1`); both clear its `>= 1.2.0`
   bar — and on the `terminalProgressBarEnabled` setting, which defaults on.
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

A fourth input, **the foreground process**, is not a terminal signal but a
selector: it decides which rule set reads the three signals above, or that
none is read at all (see "Foreground-process identification").

All four are exposed through **non-DEBUG accessors** on `GhosttySurfaceView`
(`readViewportText()`, `readOSCTitle()`, `readProgressReport()`,
`readForegroundPID()`) so the detector can reach them in a release build
(distinct from the `#if DEBUG` debug channel, `debug.md`). `AppModel` reaches
them through two injectable seams: `agentSurfaceReader` reads the three text
signals in one view lookup, `foregroundPIDProvider` the foreground.

### Foreground-process identification

`ghostty_surface_foreground_pid` is `tcgetpgrp` on the PTY master: the
terminal's **foreground process group**, whose id is its leader's PID (`0`
when unknown). Each scraped tick classifies that leader
(`ForegroundProcessClassifier`, CasperCore `ForegroundProcess.swift`) into one
of four kinds, and the kind chooses what the signal pipeline does
(`AgentDetectionRuleSet.signal(foreground:viewport:title:progress:)`):

| Foreground kind       | Per-surface signal                                 | Viewport read |
| --------------------- | -------------------------------------------------- | ------------- |
| `.agent(CodingAgent)` | that agent's rule set (viewport + title) ⊕ OSC 9;4 | yes           |
| `.shell`              | `absent`                                           | **no**        |
| `.other(name:)`       | union of every rule set ⊕ OSC 9;4                  | yes           |
| `.unidentified`       | union of every rule set ⊕ OSC 9;4                  | yes           |

`.other` is readable but neither a known agent nor a lone shell (`vim`, `ssh`,
`tmux`, `npx …`, a wrapper script) and carries the kernel name (`comm`) for
diagnostics; `.unidentified` means no PID, or a leader that could not be read
(gone, or another user's, such as `sudo claude`). The two behave alike: the
**union is the fallback**, so an agent inside ssh or tmux is still matched by
its text, and an `npm install` emitting OSC 9;4 still reads `working`. OSC 9;4
joins every case but `.shell`: it is agent-neutral, and one agent's rule set
must not hide another's progress protocol. A shell at its prompt reads
`absent` whatever the screen still shows, so a progress bar left up by an
agent that died without `ESC]9;4;0` does not pin the workspace to `working`.

**How a process is named.** `LibprocProcessInspector` reads `pbi_comm`
(`proc_pidinfo`), the resolved image path (`proc_pidpath`), the exec path as
invoked and argv (`sysctl` `KERN_PROCARGS2`) and the group's size
(`proc_listpgrppids`). The candidate names, lower-cased with a trailing `.exe`
stripped, are argv[0]'s basename (a login shell's leading `-` dropped), the
exec path's and the image path's basenames, and `comm`; behind `node`, `bun`
or `deno`, argv[1]'s basename without `.js`/`.mjs`/`.cjs` too. The first
**exactly** equal to an agent's `CodingAgent.executableNames` wins, so
`claude-monitor` is not Claude Code. argv is what names native Claude Code: its
installer links `~/.local/bin/claude` to a versioned file, so its `p_comm` and
image basename are the version (`2.1.319`). npm installs of Claude Code and
opencode run the native binary as `claude.exe` / `opencode.exe`; `@openai/codex`
`execve`s into its native binary, or, on a Node that cannot, leaves `node`
leading the group with argv[1] `…/codex.js`, which names it. The facts behind
these rules are in [[foreground-process-identification]].

**The lone-shell rule.** A name in the shell set (basenames of `/etc/shells`
plus the login shell's from `getpwuid`, for `fish`/`nu`) is `.shell` only
**alone in its group**. An interactive shell at its prompt is; a shell
*script* does no job control, so a script wrapping an agent leads a group that
holds the agent and reads `.other`, the union. The PTY's session leader is
`/usr/bin/login` and the shell its child with a group of its own, so "process
group == session" never identifies the shell. Agents are matched first, for a
`.casper.json` script surface spawned through `bash -l -c "exec …"`.

**Caching.** `ForegroundTracker`, keyed by surface id, keeps each surface's
last `ProcessKey` (PID + `comm`, since `exec` keeps the PID) and its
classification. An unchanged key reuses it; a changed one takes a fresh
snapshot. A snapshot whose `KERN_PROCARGS2` read fails (an exit or `exec` in
flight) is `nil`, so that tick is `.unidentified` and the next one retries
rather than cache a classification made without argv. A cached shell-named
leader re-counts its group on every call: a prompt's `$(…)` joins the shell's
group for an instant (`.other` that tick). The tracker prunes closed panes only
on ticks that visit every workspace (the background stride), so a background
pane a selected-only tick skips keeps its entry.

**The exit edge.** An observation reports `agentExited` when the kind becomes
`.shell` and the surface's last identified kind was an agent. Neither
`.unidentified` (the tick where `tcgetpgrp` still names the dead agent's group)
nor a shell-led `.other` (a prompt's `$(…)`) updates that last kind, so neither
swallows the edge. Agent → agent (a restart) and agent → `.other` are not
exits; ⌃Z is, since the shell takes the terminal back.

**Cost.** A shell pane trades a full-viewport read for `tcgetpgrp`, one
`proc_pidinfo` (≈ 0.75 µs) and one `proc_listpgrppids` (≈ 24 µs); an agent pane
adds ≈ 2 µs and evaluates one rule set instead of three; a new foreground job
costs one `KERN_PROCARGS2` read into a reused `KERN_ARGMAX`-sized buffer. The
inspector is a non-`Sendable` class holding those buffers, so it stays inside
the main actor's tick; `AppModel` creates it lazily, on the first tick.

### Rules

A small, **data-driven** matcher (`AgentDetectionRuleSet`) yields a raw signal
from the two text sources; the progress report needs no patterns and maps
straight through `AgentSignal(progress:)`. The patterns are held as values on
the rule set (not hard-coded control flow) so a new agent is just a new rule
set; the aspiration is to move them to an external, updatable resource so they
can track the agent's UI without a recompile. Viewport matching is
case-insensitive.

Three rule sets exist — `claudeCode`, `codex` and `opencode` — and
`AgentDetectionRuleSet.all` collects them. A surface whose foreground is an
identified agent is read with that agent's rule set alone
(`AgentDetectionRuleSet.ruleSet(for:)`). Any other surface but a shell at its
prompt falls back to applying **all** of them to the same snapshot and
aggregating the signals; each rule set's needles are specific enough to stay
quiet on another agent's screen. The rules below name the agent each pattern
was measured against.

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
  `esc to cancel` affordance (one group per rule set, not a family of
  variants), or opencode's
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
`TERM_PROGRAM_VERSION=1.3.1` (what a Casper terminal set on the libghostty pin
of the time; the current pin sets `1.4.1-HEAD+042b16b61`, and both clear Claude
Code's `>= 1.2.0` bar) and grepping the raw file for `ESC]9;4;` and `ESC]0;`.
Re-run that capture before trusting any row after an agent upgrade. Against the
live app, `casper debug dump-state` reports `agentState` (what detection
concluded, which the sidebar icon renders), `oscTitle`, `progressReport` and
`foregroundProcess` (the kind that picked the rule set) for the exposed
surface, and `casper debug read-text` gives the viewport — together they
diagnose a detection failure with no temporary logging.

| Agent               | OSC 9;4 progress                                            | OSC title                                                             | Viewport affordance                                                                                  |
| ------------------- | ----------------------------------------------------------- | --------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| Claude Code 2.1.239 | `9;4;3` for the whole turn, `9;4;0` at its end              | `◐◑` while working, `✳` at rest                                       | none                                                                                                 |
| opencode 1.18.20    | none                                                        | plain ASCII (`OpenCode`, `OC \| <turn title>`) — never a glyph prefix | `esc interrupt` footer while a turn runs; `Permission required` + `Allow once`/`Reject` when blocked |
| codex-cli 0.149.0   | none (static: the binary contains no `9;4` and no `ConEmu`) | not measured                                                          | not measured                                                                                         |

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
  download — reads as `working` for its workspace. That is defensible
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

**It is reachable at runtime.** A surface whose foreground identifies as Codex
(`codex`, `codex.exe`, or `node` running `codex.js`) is read with this rule set
alone, so the `Running tools` needle contributes there and no other agent's
needles do. A surface the foreground cannot name (Codex inside ssh or tmux)
falls back to every rule set in `AgentDetectionRuleSet.all`, aggregated, which
is what keeps Codex detected there; opencode's `esc interrupt` footer and
`Permission required` prompt are reachable the same two ways.

### Resolver

The raw signal becomes the reported state through `AgentStateResolver` — the
only place with policy, and the only state machine involved: the model's
`agentState` stays a plain field (`core.md`).

1. **A shell foreground → `unknown`.** The tick feeds `absent` for a terminal
   whose foreground is a shell at its prompt, so a workspace whose every
   terminal is at its shell aggregates to `absent`. `absent` joins `idle`'s
   at-rest path (`resolveAtRest`) and differs only in the rest state: a
   resolver that saw no work returns `unknown` at once; one that saw work goes
   through the same debounce, presents `done` while unseen, then rests at
   `unknown` once seen. "Agent ran, then the shell came back" therefore
   resolves exactly like "agent ran, then went quiet", and the debounce absorbs
   `claude -p a; claude -p b` typed as one line, where the shell holds the
   terminal for an instant between the runs. A workspace with no readable
   terminal this tick (no live view) is still *skipped*, its prior state left
   untouched rather than forced to `unknown`, so an unvisited workspace is not
   clobbered.
2. **Debounce transitions.** Require the `working` affordance to be **absent for
   N consecutive reads** before `working → idle`, so a gap between two tool
   calls does not flicker to idle. Never let a late or stale read revive `idle`
   once a terminal state has been set. N is **2** — the default of
   `AgentStateResolver.resolve(signal:seen:debounce:)` — and it counts *ticks*,
   not seconds: against the fixed 250 ms visible / 1 s hidden cadence (see
   Wiring) that is ~0.5 s on screen and ~2 s behind a hidden window. All three
   numbers are compiled-in constants; there is no tuning seam.
3. **Priority (multi-signal / aggregation):** `AgentSignal` has four cases and
   ranks them `blocked` > `working` > `idle` > `absent`, so rolling several
   surfaces up is a `max`. `done` is not in that order: it is a *state*, derived
   from an aggregated `idle` or `absent` by `AgentStateResolver.resolveAtRest`.
4. **`done` is derived, not matched.** A `working → idle` transition — or
   `working → absent`, the agent exiting back to its shell — while the
   workspace is **unseen** presents as `done`; it collapses to `idle` (to
   `unknown` after an exit) once seen (`focusedSurfaceID` /
   `selectedWorkspaceID` point at it). `done` is the pre-notification attention
   state.

## Authority: explicit CLI vs detection

Explicit reporting and detection must not fight. A per-workspace, **transient**
latch decides who owns the state:

There is no `AgentAuthority` enum: the latch as built is a set of workspace ids,
`explicitAuthority: Set<UUID>` on `AppModel`, read directly — the detection tick
tests `explicitAuthority.contains(id)`, with no accessor in between. Membership
means the workspace is under explicit authority; absence means detection owns
it.

- Default (not a member) — the scraper drives `agentState`.
- `working`, `blocked`, `done`, and `error` all grant authority. For the
  attention states the reason is that a terminal scrape cannot safely *clear*
  them. For `working` it is that the claim is about work the terminal cannot
  see: an agent that dispatches background subagents and ends its turn to let
  them run leaves a viewport at rest — no interrupt affordance, OSC 9;4;0 —
  which the resolver reads as `idle` and then `done` within a couple of ticks.
  Were `working` to release the latch, an explicit one would survive under a
  second, and no agent could report "still busy, look elsewhere for why".
- `idle` and `unknown` **release** it: both mean "nothing to say about this
  workspace", so the scraper takes back over.
- An **observed agent exit** releases it too (see "Release on an observed
  agent exit").
- The `Stop` hook still reports `done` precisely; selecting that workspace then
  collapses the explicit `done` back to `idle` (below).
- The latch is **not persisted** — the set starts empty on load, like the agent
  state it guards.

**What a latched `working` costs.** Detection is suppressed for as long as it
holds, so a `blocked` the viewport *could* have matched (a permission prompt) is
not detected there — a hook-driven session reports blocked through its
notification hook instead, which is the path that already carries it. A stale
`working` heals from the terminal only through the exit release below: an agent
killed between its `UserPromptSubmit` hook and the matching `Stop` inside ssh
or tmux, launched through a wrapper, `npx` or `sudo` (never identified, so its
exit is no edge), in a pane that is closed, or beside a pane that never returns
to its shell, leaves the workspace `working`. What ends it there is the session
boundary — the plugin's SessionEnd hook reports `done`, its SessionStart
reports `idle` (a release), and the latch never survives an app reload — plus
the plugin's own rule that a turn ending with no progress bar up reports
`done`.

### Release on an observed agent exit

Under the latch the tick still observes every terminal's foreground on the
ticks that scrape the workspace, but reads no viewport. An `agentExited`
observation is remembered in `agentExitedUnderAuthority`: the edge lasts a
single tick, and another pane may not be at its shell on that tick (a dev
server, a prompt's `$(…)`). The latch releases on the first scraped tick where
an exit is remembered **and every terminal is `.shell`**:

- **Every pane, not the agent's.** The explicit claim names no pane, so every
  pane at a shell is the only proof no agent is left to have made it. A pane
  that is `.other` or `.unidentified` (an agent in ssh or tmux, a running dev
  server) may hold that agent, and blocks the release until it is at its shell.
- **Never on `error`.** That verdict only the agent could reach stays until the
  next explicit report.
- **Any explicit `casper status set`** forgets a remembered exit, since the
  agent spoke again; so does removing the workspace. A late hook (SessionEnd's
  `done` landing after a release) simply re-latches.
- **Seeding.** On release the workspace's resolver resumes from the state the
  latch held (`AgentStateResolver(resumingFrom:)`) and detection runs in the
  same tick, feeding `absent`: an explicit `working` (an agent killed
  mid-turn) stays `working` through the debounce, then presents `done` while
  unseen — raising the passive "Done" notification through
  `setDetectedAgentState` — or `unknown` once seen; an explicit `done` stays
  `done` until seen, then `unknown`; an explicit `blocked` resolves `unknown`,
  the prompt having died with its agent.
- ⌃Z on a hook-driven agent counts as an exit. The user pressing it is looking
  (`unknown`); after `fg`, the agent's next hook re-asserts its state.

### Explicit-authority `done` → `idle` collapse (on selection)

An explicit `done` suppresses detection, so `AppModel.selectWorkspace` collapses
it to `.idle` when selected. This mirrors the resolver's own "seen" definition
(`selectedWorkspaceID` pointing at it — not gated on `isWindowKey()`, unlike the
sibling bubble-clear in `clearNotificationForFocusedWorkspace()`). Only `done`
collapses this way; `blocked` and `error` are untouched.

This exists because a hook-driven workspace stays under explicit authority for
as long as its agent runs, and so never gets a *detected* `done` for a turn:
the plugin's `Stop` hook reports `done` outright rather than `idle`, and the
collapse is what lets that state end. Both halves are built — the plugin maps
`turn-end` to `casper status set done`.

## Process lifecycle: the exit edge, no exit code

`done` and `error` are in the `AgentState` model. The foreground process gives
detection an agent's **exit edge** — the shell back in front of a terminal whose
last identified foreground was an agent (see "Foreground-process
identification") — but never its **exit code**, so there is no detected
`error`:

- **The shell reaps the job**, so the agent's exit status is visible to the
  shell alone.
- **Ghostty's shell integration is not active** in a Casper terminal, because
  Casper ships no Ghostty resources directory; its OSC 133 marks are what could
  have carried the status out.
- **`GHOSTTY_ACTION_SHOW_CHILD_EXITED`** fires for the surface's own process —
  the login shell — not for a job inside it. A process-exit event mapping exit
  `0 → done` / `≠0 → error` would need an *agent-as-command* surface, and
  Casper has none:

**`--command` does not create an agent-as-command surface.** The pinned fork
(`libghostty-spm`, a sandbox/host-managed-oriented fork) execs a surface's
`command` through a hardcoded `bash -l -c "exec <command>"`, ignoring the user's
real shell. `terminal new --command` therefore deliberately types the text into
the already-spawned login shell via `ghostty_surface_text` — not `exec`'d, and
using neither the `command` nor the `initial_input` config field — so it does
not replace the shell process. See [[ghostty-initial-input-utf8]]. Agents always
run **inside a shell** (the user types `claude`, or `--command claude` types it
for them); the shell survives when the agent exits, and no agent-scoped exit
event is available. See the CasperGhostty note in `cli-agents.md`.

Given the shell-hosted reality:

- **`done`** is produced by the resolver from `working → idle` (the agent
  finishes, its at-rest screen unseen) and from `working → absent` (the agent
  exits back to its shell, unseen). A crashed agent therefore resolves like a
  finished one: `done` unseen, `unknown` seen.
- **`error`** has no detected producer. It is produced outside detection, by a
  `.casper.json` `setup` hook that exits non-zero (`ScriptHookRunner` → its
  injected `reportSetupFailure` closure →
  `AppModel.setDetectedAgentState(.error, …)`), and explicitly by
  `casper status set error`.
- **Authority release** — see "Release on an observed agent exit".

## Aggregation (per-workspace)

`agentState` stays **per-workspace**; a workspace can hold several terminal
panes. The detector rolls the per-surface raw signals up to the **most urgent**
using the resolver priority above. Which surfaces feed the rollup: **every
terminal surface** of the workspace, however it was launched — an agent run
inside any shell is identified by its process, and one the foreground cannot
name (inside ssh or tmux) is still matched by its text. A terminal at its shell
contributes `absent`, the lowest signal, so it never outvotes an agent pane,
and a workspace whose every terminal is at its shell aggregates to `absent`.
**No `Surface.status` field is added** in v1 — detection state lives only at
the workspace level.

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
  Deferred.) A fourth non-DEBUG accessor, `readForegroundPID()`, wraps
  `GhosttySurface.foregroundPID()` over `ghostty_surface_foreground_pid`, the
  only `ghostty_*` call identification makes; `0`, or a value no `pid_t` holds,
  is `nil`.
- **CasperCore** — the revised `AgentState` and the pure engine
  (`AgentDetection.swift`): `signal(fromViewport:)`, `signal(fromTitle:)`
  (classifying the spinner / `✳` title prefixes), and `AgentSignal(progress:)`
  over the CasperCore-level `AgentProgressState` — a one-for-one restatement of
  `ghostty_action_progress_report_state_e` so the C enum never reaches
  CasperCore, which must not depend on GhosttyKit. The per-surface combination
  is `AgentDetectionRuleSet.signal(foreground:viewport:title:progress:)` over
  `ruleSet(for:)`, and `AgentStateResolver(resumingFrom:)` seeds a released
  workspace. Identification is `ForegroundProcess.swift`: `ForegroundProcess`,
  `ProcessSnapshot`, `ProcessKey`, the `ProcessInspector` seam and its libproc
  implementation `LibprocProcessInspector`, `ForegroundProcessClassifier`, and
  `ForegroundTracker` with its `ForegroundObservation`; the agents' process
  names are `CodingAgent.executableNames`. libproc and `sysctl` are system
  libraries, so the dependency policy holds.
- **CasperUI** — a detector owned by `AppModel` (main actor): a timer that ticks
  every ~250 ms while the window is visible and is throttled to ~1 s while it is
  hidden — it is never stopped (`agentDetectionIntervalVisible` /
  `agentDetectionIntervalHidden`). Not every workspace is read on every tick:
  the selected one always is, and the rest only every fourth tick
  (`backgroundDetectionStride`). Scraping is the expensive half — one viewport
  read per surface — and a workspace nobody is looking at only has to be right
  by the time they look, so the stride buys back most of that cost without
  changing what any state eventually resolves to. For each workspace it
  scrapes, `runAgentDetectionTick` first observes every terminal's foreground
  through `foregroundTracker` (the PID from `foregroundPIDProvider`, the
  process read by `processInspector`). A workspace under explicit authority
  stops there unless the exit release applies (§ Authority: explicit CLI vs
  detection). Otherwise a terminal at its shell yields `absent` without a
  viewport read, and every other one is read through `agentSurfaceReader`
  (viewport, OSC title **and** OSC 9;4 progress state) and turned into a signal
  by `AgentDetectionRuleSet.signal(foreground:…)`; the tick aggregates the
  signals, runs the resolver, and writes `agentState` via
  `setDetectedAgentState`. A tick that visits every workspace then prunes the
  tracker to the terminals it saw. `foregroundPIDProvider`, `processInspector`
  and `agentSurfaceReader` are test seams (in the shape of
  `agentIntegrationProbe`), so the tick runs in tests with no surface and no
  real process table. The sidebar status icon lives on `WorkspaceRow`
  (monochrome outline SF Symbols in the chevron column, animated `working`).
- **Debug** (`#if DEBUG`) — `dump-state` reports each surface's last observed
  kind as `foregroundProcess` (`debug.md`), from the tracker through
  `DebugSurfaceBridge`. Classification changes are not logged: the tick is hot.

### Notifications

`setDetectedAgentState` raises a notification on a transition into an attention
state — `blocked` → `"Waiting for your input"`, `done` → `"Done"`, `error` →
`"Something went wrong"` — by calling `controlRaiseNotification(message:for:)`,
the same mechanism `casper notify` uses. This is what makes notification +
sidebar-dot support work **with no Claude Code hook**: it is driven purely by
Casper's own OSC/viewport scraping rather than an explicit CLI call. The write
is edge-triggered (the "only on change" guard), so a steady detection stream
notifies once per transition, and `controlRaiseNotification`'s focus semantics
still apply: **a focused workspace gets neither** — the same `!focused` guard
covers the sidebar dot and the macOS notification, so nothing is raised for the
workspace the user is already looking at. A `done` notification is `.passive` —
a silent addition to Notification Center, with no banner and no sound — while
`blocked` and `error` post `.active` ones with the sound
(`AppModel.interruptionLevel(for:)`).

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
callers (the casper-skills plugin's `blocked.py` hook, the `casper` skill),
so mirroring `setDetectedAgentState` there would double the notification.

Arming the bubble also drives the Dock icon — a bounce that runs until Casper is
activated, plus a badge counting the unread workspaces. Their exact clearing
rules live in `app-ui.md` § Design → "Dock attention".

## Deferred / out of scope

- **`.render`-driven trigger** — replace the timer poll (~250 ms while the
  window is visible, ~1 s while it is hidden) with a throttled (~150–300 ms)
  re-read on `GHOSTTY_ACTION_RENDER`, which is decoded as `.render` and
  discarded. It is handled app-wide, so it would first need the per-surface
  `userdata` target resolution `casperGhosttyAction` already does for
  `MOUSE_SHAPE`, `MOUSE_VISIBILITY`, `SET_TITLE`, `PROGRESS_REPORT` and
  `SHOW_CHILD_EXITED` — that is what says *which* surface changed.
- **Timeout-based authority release** for shell-hosted agents (option B), wired
  with `casper notify` — for the panes the exit release cannot read as back at
  their shell (ssh, tmux).
- **A real `error` signal** and the **agent-as-command** `done`/`error` path —
  the exit edge is seen but carries no code, and the `--command` reliability
  fix shipped (see "Process lifecycle") deliberately without `exec` semantics,
  so it does not itself create an agent-as-command surface; re-evaluating that
  path is a separate, unscoped project.
- **Per-surface explicit status** (step 2 of foreground identification) — wrap
  `ghostty_surface_tty_name` next to `foregroundPID()` so a `casper status set`
  maps to the pane that sent it (its tty → surface id). The exit release then
  narrows from "every pane at a shell" to "the reporting pane's agent exited";
  the tracker is already keyed by surface id.
- **Per-surface status** field + pane-chrome indicator (option B).

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
- **Several agents in one workspace.** Partly answered: each terminal's
  foreground picks its own rule set, so two agents in two panes are each read
  with their own rules and roll up by urgency. Still open: one workspace state
  stands for all of them, and an explicit claim names no pane (see "Per-surface
  explicit status" above).
- Whether the rule set ships as an in-repo resource or is fetched/updatable.
