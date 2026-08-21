# Stop Hook Explicit `done` — Design

**Date:** 2026-07-09 **Status:** Partly shipped — the Casper-side half
(selecting a `done` workspace collapses it to `idle`) is built; the
`casper-claude-plugin` `hooks/stop.sh` half is not **Scope:** Make Claude Code's
`Stop` hook explicitly report `done` instead of `idle`, and make the app
collapse an unseen `done` back to `idle` when the workspace is finally selected.
Spans two repos: `casper-claude-plugin` (`hooks/stop.sh`) and this one
(`Sources/CasperUI/AppModel.swift`: `controlSetAgentState`, `selectWorkspace`).

## Problem

[`plans/notification-idle-best-practices.md`](notification-idle-best-practices.md)
(shipped 2026-07-08) stripped the unconditional `casper notify` call from
`hooks/stop.sh`, leaving only `casper status set idle`, on the stated assumption
that "Casper's detection engine ... becomes the sole trigger for the 'task
finished' notification, via the existing `working → idle (unseen) →
done` derivation."

That assumption doesn't hold in practice. `hooks/user-prompt-submit.sh` and
`hooks/pre-tool-use.sh` both call `casper status set working` — the very first
Claude Code turn in a Casper-terminal workspace flips it into
`explicitAuthority` (`controlSetAgentState`, `themes/agent-state-detection.md` §
Authority). Authority release is not yet implemented ("stays latched until
reload"), so **every workspace driven by this plugin stays under explicit
authority for the rest of the session** — the terminal-scraping detector (and
its `working → idle (unseen) → done` derivation) never runs for it. `done`
cannot ever be produced by detection for a Claude-Code-managed workspace; only
`stop.sh` itself can report it, and today it reports `idle` instead.

Net effect: a Claude Code turn finishing while its workspace isn't selected
today shows `idle`, with no attention signal at all — not the quiet `done` +
passive notification the previous design intended.

## Goals

- `hooks/stop.sh` reports `done` explicitly, so the sidebar icon and the
  attention bubble both reflect "finished, not yet looked at" — matching what
  detection already does for non-hook-driven agents.
- Selecting a `done` workspace collapses it back to `idle`, mirroring the
  resolver's own seen-gated latch/unlatch (`agent-state-detection.md` §
  Resolver, point 4), extended to the explicit-authority path where the resolver
  itself never runs.
- No new `AgentState` case — "seen, no longer flagged" is `.idle`, exactly as
  detection already models it.

## Non-Goals

- No change to `blocked`/`error` handling in `controlSetAgentState` — see Design
  below for why.
- No authority-release/timeout mechanism — still deferred, tracked in
  `agent-state-detection.md` § Deferred. This plan works within the
  permanent-latch reality, it doesn't fix it.
- No change to `casper-claude-plugin`'s `hooks/notification.py` or the
  `casper-status` skill.

## Design

### `casper-claude-plugin`

`hooks/stop.sh`:

```bash
casper status set done >/dev/null 2>&1 || true
```

Update the script's comment (it currently claims detection covers this, which
the Problem section shows is false for any workspace this plugin drives), the
README hook table row, and `tests/test_stop.sh`'s expected CLI args.

### Casper

#### `controlSetAgentState` raises the bubble + notification — `.done` only

```swift
@discardableResult
func controlSetAgentState(_ state: AgentState, for workspaceID: UUID) -> Bool {
    guard let at = locate(workspaceID) else { return false }
    spaces[at.space].workspaces[at.workspace].agentState = state
    explicitAuthority.insert(workspaceID)
    if state == .done {
        controlRaiseNotification(message: Self.notificationMessage(for: .done), for: workspaceID)
    }
    persist()
    return true
}
```

Scoped to `.done` deliberately, **not** a blanket reuse of
`notificationMessage(for:)` across `blocked`/`done`/`error` (i.e. not a literal
mirror of `setDetectedAgentState`): `blocked` already gets an explicit
`casper notify` call from its own caller — `hooks/notification.py` calls
`casper status set blocked` *and then* `casper notify --message ...` separately
for `permission_prompt`/ `elicitation_dialog`, and the `casper-status` skill
documents the same two-call pattern for Claude's own judgment calls. Raising a
notification from inside `controlSetAgentState` for `blocked` too would double
it — exactly the failure mode `notification-idle-best-practices.md` was written
to eliminate. `done` has no such second caller (`stop.sh` only ever calls
`status set`), so it's safe to raise from here, and it must be raised from here
— nothing else will.

`error` is left alone for the same reason (`casper-status` skill's documented
`casper status set error` + optional manual `casper notify`) and because it
isn't reachable from this plan's flow.

#### `selectWorkspace` collapses `.done` → `.idle`

```swift
func selectWorkspace(_ id: UUID?) {
    selectedWorkspaceID = id
    reconfigureWorktreeWatcher()
    guard let id, let ws = workspace(id: id) else { return }
    if let si = spaces.firstIndex(where: { $0.workspaces.contains { $0.id == id } }),
       spaces[si].isCollapsed {
        withAnimation(.snappy) { spaces[si].isCollapsed = false }
    }
    focusedSurfaceID = LayoutTree.surfaceIDs(ws.layout).first
    focusActiveSurfaceView()
    clearNotificationForFocusedWorkspace()
    if spaces.indices.contains(at: id).map({ spaces[$0.space].workspaces[$0.workspace].agentState }) == .done {
        // (illustrative — real diff resolves the (space, workspace) index once,
        // shared with the existing locate(_:) helper, and writes agentState = .idle)
    }
    persist()
}
```

(The snippet above is illustrative of intent, not the literal diff — the real
change resolves `at = locate(id)` once, checks
`spaces[at.space].workspaces[at.workspace].agentState == .done`, and if so sets
it to `.idle`, alongside the existing `clearNotificationForFocusedWorkspace()`
call.)

Deliberately **not** gated on `isWindowKey()` the way
`clearNotificationForFocusedWorkspace()` is: the resolver's own definition of
"seen" (`agent-state-detection.md` § Resolver, point 4: `selectedWorkspaceID`
pointing at the workspace) doesn't check window-key state either, so the
explicit-authority path stays consistent with it. This means the two attention
signals can momentarily disagree — the icon may flip to `.idle` on selection
while the app is backgrounded, before the bubble clears once focus returns —
which mirrors the existing, deliberate split between "seen" (selection) and
"focused" (selection + key window) already documented for the bubble.

Only `.done` collapses. `blocked`/`error` are left as-is: neither the resolver
nor this plan gives selection any power over them — they clear only via another
explicit `casper status set` call.

## Edge Cases

- Repeated `Stop` events between selections (the workspace is never looked at
  across several turns): `controlSetAgentState(.done, ...)` is called again each
  time; the write is a same-value no-op for `agentState`, and
  `controlRaiseNotification`'s existing per-workspace cooldown
  (`notification-idle-best-practices.md` § Per-workspace de-dup cooldown)
  prevents notification spam. The bubble stays armed the whole time, which is
  correct — still unseen.
- A workspace already `.blocked` or `.error` never gets silently overwritten to
  `.done` by a stray `Stop` mid-flow in this plan's scope — `Stop` only fires at
  the actual end of a turn, same as today.
- `explicitAuthority` staying permanent means a workspace can never again fall
  back to detection this session — unchanged, pre-existing behavior, not
  something this plan makes worse.

## Testing

- `casper-claude-plugin`: `tests/test_stop.sh` expects `status set done`; README
  hook table updated.
- Casper (XCTest):
  - `controlSetAgentState(.done, ...)` sets `pendingNotification` /
    `pendingNotificationMessage` (extends the existing pattern in
    `ControlHandlerTests.swift`/`AgentDetectionTests.swift`, which already call
    `controlSetAgentState` for other states).
  - `controlSetAgentState(.blocked, ...)` / `(.error, ...)` do **not** set
    `pendingNotification` — regression guard for the double-notify scenario this
    plan avoids.
  - `selectWorkspace` on a `.done` workspace sets `agentState == .idle`.
  - `selectWorkspace` on a `.blocked` / `.error` workspace leaves `agentState`
    unchanged.
- Manual, via `debug-casper` + a real Claude Code session in a Casper terminal:
  finish a turn without looking at the workspace → icon shows `done`, bubble
  armed, one passive notification; select the workspace → bubble clears, icon
  reverts to `idle`.

## Out of Scope / Deferred

- Authority-release/timeout mechanism (`agent-state-detection.md` § Deferred) —
  this plan works within the permanent-latch reality.
- Raising notifications from `controlSetAgentState` for `blocked`/`error` — not
  needed (both already notify via their own callers) and would regress the
  de-dup work in `notification-idle-best-practices.md`.
