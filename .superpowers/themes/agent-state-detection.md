# Theme: Agent State Detection (CasperGhostty + CasperCore + CasperUI)

**Modules:** CasperGhostty, CasperCore, CasperUI · **Status:** ◐ built —
detection (working/blocked/idle) is live and verified; the process-exit
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
| `working` | executing | detection (viewport) |
| `blocked` | waiting on the user | detection (viewport) |
| `idle` | at rest, seen | detection (viewport) |
| `done` | at rest, unseen | derived (see resolver) |
| `error` | abnormal exit | `.childExited(exitCode: ≠0)` |
| `unknown` | no signal | resolver default |

## Detection

### Reading the terminal

Reuse `GhosttySurface.readText(scrollback: false)` — it fabricates a
full-**viewport** selection and calls `ghostty_surface_read_text`, returning
plain UTF-8 synchronously on the main thread. Read the **viewport only**, never
the full scrollback, on every tick: the affordances we match are always on the
visible screen, and scraping scrollback each time is needlessly expensive.

Today that method is only reachable through the `#if DEBUG` debug channel
(`themes/debug.md`). This theme needs a **non-DEBUG accessor** on
`GhosttySurfaceView` / `AppModel` so the detector can reach it in a release
build.

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

A small, **data-driven** matcher runs over the viewport text and yields a raw
signal. The patterns describe Claude Code's on-screen affordances and should
live in an external resource (not hard-coded) so they can track the agent's UI
without a recompile. Matching is case-insensitive.

- **`working`** — the interrupt hint the agent shows **only while it runs**:
  `esc to interrupt`, `press esc to interrupt`, `ctrl+c to interrupt`, or a
  `running tools` line alongside `esc to interrupt`. Its disappearance is the
  primary "no longer working" signal.
- **`blocked`** — a pending confirmation the agent shows **only while it waits
  for the user**: `do you want to proceed?` together with an `esc to cancel`
  affordance (and sibling confirmation prompts).
- **`idle`** — none of the above; the prompt is at rest.

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

## Process lifecycle: `done` / `error` — not implemented

`done` and `error` are in the `AgentState` model, but there is **no detected
producer** for them, by decision. The obvious source — a process-exit event
(`GHOSTTY_ACTION_SHOW_CHILD_EXITED`) mapping exit `0 → done` / `≠0 → error` —
was implemented and then **removed**, because it only makes sense for an
*agent-as-command* surface (`Surface.terminal(command: "claude")`) and that
scenario does not exist in Casper today:

**The embedded libghostty does not spawn a surface's `command`.** The pinned
binary (`libghostty-spm`, a sandbox/host-managed-oriented fork) does not honor
`ghostty_surface_config_s.command` — both `casper terminal new --command X` and
restored command-surfaces launch a plain login shell instead. So agents always
run **inside a shell** (`command == nil`, the user types `claude`); the shell
survives when the agent exits, and no agent-scoped exit event is available. See
the CasperGhostty note in `themes/cli-agents.md`.

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

- **CasperGhostty** — non-DEBUG `readViewportText()` accessor. (A
  `.render`-driven trigger is deferred; see Deferred.)
- **CasperCore** — the revised `AgentState` and the pure engine
  (`AgentDetection.swift`).
- **CasperUI** — a detector owned by `AppModel` (main actor): a ~250 ms timer
  scrapes each workspace's terminals, runs the resolver, and writes `agentState`
  via `setDetectedAgentState` unless the workspace is under explicit authority.
  The authority latch is set in `controlSetAgentState` (`casper status set`);
  its release is deferred (option B). The sidebar status icon lives on
  `WorkspaceRow` (monochrome outline SF Symbols in the chevron column, animated
  `working`).

## Deferred / out of scope

- **Notifications.** `blocked` and `done` are the future triggers for
  `casper notify` + `pendingNotification`; not wired here. This theme produces
  **states only**.
- **`.render`-driven trigger** — replace the ~250 ms timer poll with a
  throttled re-read on `GHOSTTY_ACTION_RENDER` (decoded as `.render`, currently
  discarded).
- **Timeout-based authority release** for shell-hosted agents (option B),
  wired with `casper notify`.
- **A real `error` signal** and the **agent-as-command** `done`/`error` path —
  both blocked on the embedded libghostty honoring a surface's `command` at
  spawn (see "Process lifecycle").
- **Per-surface status** field + pane-chrome indicator (option B).
- **Agents beyond Claude Code** — the rule set is per-agent.

## Open questions

- Which surfaces feed the workspace rollup when more than one agent runs in a
  workspace.
- Exact debounce count N and throttle interval — tuned live.
- Whether the rule set ships as an in-repo resource or is fetched/updatable.
