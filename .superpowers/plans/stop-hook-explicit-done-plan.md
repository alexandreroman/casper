# Stop Hook Explicit `done` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Claude Code's `Stop` hook report `done` (not `idle`) so a
finished, unseen turn shows in Casper's sidebar and raises its attention
bubble; make selecting a `done` workspace collapse it back to `idle`.

**Architecture:** `hooks/stop.sh` (in `casper-claude-plugin`) switches its one
`casper status set` call from `idle` to `done`. In Casper,
`AppModel.controlSetAgentState` gains a `.done`-only branch that raises the
same attention bubble + passive notification `setDetectedAgentState` already
raises for a detected `done` — scoped to `.done` alone, since `blocked`/`error`
already notify via their own callers and mirroring them here would double it.
`AppModel.selectWorkspace` gains a `.done → .idle` collapse on selection,
mirroring the resolver's own seen-gated unlatch for the explicit-authority
path the resolver itself never runs for.

**Tech Stack:** Bash (plugin hooks), Swift 6 + XCTest (Casper app).

## Global Constraints

- Design source of truth: `.superpowers/plans/stop-hook-explicit-done.md`
  (approved).
- No new `AgentState` case — "seen, no longer flagged" is `.idle`.
- Only `.done` gets the new notify-on-explicit-set behavior and the
  select-to-collapse behavior; `.blocked`/`.error` are untouched by both.
- The `.done → .idle` collapse in `selectWorkspace` is **not** gated on
  `isWindowKey()` — it uses the resolver's own "seen" definition (selection
  alone), unlike the sibling bubble-clear which requires the window to be key.
- Two repos: Task 1 is in `casper-claude-plugin` (a sibling checkout, not this
  one); Tasks 2–4 are in this repo (`casper`).

---

### Task 1: `casper-claude-plugin` — `Stop` hook reports `done`

**Files** (repo: `casper-claude-plugin`, e.g. `/Users/alex/Projects/personal/casper-claude-plugin`):
- Modify: `hooks/stop.sh`
- Modify: `tests/test_stop.sh`
- Modify: `README.md` (hook table, `Stop` row)

**Interfaces:**
- Consumes: nothing new — same `casper status set <state>` CLI already used
  by every other hook in this plugin.
- Produces: nothing consumed by Tasks 2–4 (independent repo) — this task is
  purely `casper-claude-plugin`-local and can run before, after, or in
  parallel with Tasks 2–4.

- [ ] **Step 1: Update the failing test's expectation**

In `tests/test_stop.sh`, change:

```bash
expected=$'status\nset\nidle\n---'
```

to:

```bash
expected=$'status\nset\ndone\n---'
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_stop.sh`
Expected: `FAIL: expected [status\nset\ndone\n---], got [status\nset\nidle\n---]`

- [ ] **Step 3: Update `hooks/stop.sh`**

Replace the whole file with:

```bash
#!/usr/bin/env bash
# Report done explicitly. Every workspace this plugin drives is under
# Casper's explicit-authority latch from the very first `casper status set
# working` call onward (user-prompt-submit.sh / pre-tool-use.sh) — which
# permanently suppresses Casper's terminal-scraping detector for it, so
# detection can never derive "done" here on its own. Casper collapses this
# back to idle once the workspace is selected (seen).
casper status set done >/dev/null 2>&1 || true
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test_stop.sh`
Expected: `PASS`

- [ ] **Step 5: Update the README hook table**

In `README.md`, change the `Stop` row of the hook table from:

```markdown
| `Stop` | `status set idle` (Casper's own detection engine derives the "task finished" notification on its own; this hook no longer notifies) |
```

to:

```markdown
| `Stop` | `status set done` (every hook-driven workspace is permanently under Casper's explicit-authority latch, so its own detection engine can never derive "done" here — Casper collapses it back to `idle` once the workspace is selected) |
```

- [ ] **Step 6: Commit**

```bash
git add hooks/stop.sh tests/test_stop.sh README.md
git commit -m "Report done explicitly from the Stop hook instead of idle"
```

---

### Task 2: Casper — `controlSetAgentState` raises the bubble/notification for `.done`

**Files:**
- Modify: `Sources/CasperUI/AppModel.swift:1245-1256` (`controlSetAgentState`)
- Test: `Tests/CasperUITests/ControlHandlerTests.swift`

**Interfaces:**
- Consumes: `AppModel.controlRaiseNotification(message:for:) -> Bool`
  (`AppModel.swift:1292`), `AppModel.notificationMessage(for:) -> String?`
  (private static, same file, `AppModel.swift:1219`), `AgentState`
  (`CasperCore/Models.swift:3-4`, cases `working, blocked, idle, done,
  unknown, error`).
- Produces: no signature change to `controlSetAgentState(_:for:) -> Bool` —
  same call sites in `ControlServer.swift` are unaffected. Test-visible
  behavior change: `controlSetAgentState(.done, for:)` now also sets
  `Workspace.pendingNotification`/`pendingNotificationMessage` (when the
  workspace isn't already focused), exactly like `controlRaiseNotification`
  already does for any other caller.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/CasperUITests/ControlHandlerTests.swift`, right after
`testSetAgentState` (after line 335):

```swift
    func testSetAgentStateDoneRaisesNotificationBubble() {
        let (model, id) = seededModel()
        model.isWindowKey = { false }  // not focused, so the bubble should arm
        model.deliverNotification = { _, _, _, _ in }  // mock to avoid UNUserNotificationCenter crash
        XCTAssertTrue(model.controlSetAgentState(.done, for: id))
        XCTAssertEqual(model.workspace(id: id)?.agentState, .done)
        XCTAssertEqual(model.workspace(id: id)?.pendingNotification, true)
        XCTAssertEqual(model.workspace(id: id)?.pendingNotificationMessage, "Task finished")
    }

    func testSetAgentStateBlockedDoesNotRaiseNotificationBubble() {
        let (model, id) = seededModel()
        model.isWindowKey = { false }
        XCTAssertTrue(model.controlSetAgentState(.blocked, for: id))
        XCTAssertEqual(model.workspace(id: id)?.agentState, .blocked)
        XCTAssertEqual(model.workspace(id: id)?.pendingNotification, false)
    }

    func testSetAgentStateErrorDoesNotRaiseNotificationBubble() {
        let (model, id) = seededModel()
        model.isWindowKey = { false }
        XCTAssertTrue(model.controlSetAgentState(.error, for: id))
        XCTAssertEqual(model.workspace(id: id)?.agentState, .error)
        XCTAssertEqual(model.workspace(id: id)?.pendingNotification, false)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ControlHandlerTests 2>&1 | tail -40`
Expected: `testSetAgentStateDoneRaisesNotificationBubble` FAILS
(`pendingNotification` is `false`, not `true`); the other two PASS already
(no regression to guard yet, but they document the boundary this task must
not cross).

- [ ] **Step 3: Implement the `.done`-only notify branch**

In `Sources/CasperUI/AppModel.swift`, change `controlSetAgentState`
(currently lines 1245-1256) from:

```swift
    @discardableResult
    func controlSetAgentState(_ state: AgentState, for workspaceID: UUID) -> Bool {
        guard let at = locate(workspaceID) else { return false }
        spaces[at.space].workspaces[at.workspace].agentState = state
        // The explicit CLI path is the ONLY place authority is granted: once an
        // agent reports its own state, terminal-scraping detection steps aside for
        // this workspace. Robust authority release is deferred to a later timeout
        // mechanism.
        explicitAuthority.insert(workspaceID)
        persist()
        return true
    }
```

to:

```swift
    @discardableResult
    func controlSetAgentState(_ state: AgentState, for workspaceID: UUID) -> Bool {
        guard let at = locate(workspaceID) else { return false }
        spaces[at.space].workspaces[at.workspace].agentState = state
        // The explicit CLI path is the ONLY place authority is granted: once an
        // agent reports its own state, terminal-scraping detection steps aside for
        // this workspace. Robust authority release is deferred to a later timeout
        // mechanism.
        explicitAuthority.insert(workspaceID)
        // `done` is the one explicit state detection can never produce for a
        // hook-driven workspace (it's already under explicit authority by the
        // time a Stop hook fires — see
        // `.superpowers/themes/agent-state-detection.md` § Authority), so this
        // is the only place that can raise its attention bubble/notification.
        // `blocked`/`error` are deliberately excluded: both already get an
        // explicit `casper notify` from their own callers (`notification.py`,
        // the `casper-status` skill), so mirroring this for them would double
        // the notification.
        if state == .done {
            controlRaiseNotification(message: Self.notificationMessage(for: .done), for: workspaceID)
        }
        persist()
        return true
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ControlHandlerTests 2>&1 | tail -40`
Expected: PASS, including all three new tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/CasperUI/AppModel.swift Tests/CasperUITests/ControlHandlerTests.swift
git commit -m "controlSetAgentState raises the attention bubble for explicit done"
```

---

### Task 3: Casper — `selectWorkspace` collapses `.done` → `.idle`

**Files:**
- Modify: `Sources/CasperUI/AppModel.swift:477-493` (`selectWorkspace`)
- Test: `Tests/CasperUITests/ControlHandlerTests.swift`

**Interfaces:**
- Consumes: `AppModel.locate(_:) -> (space: Int, workspace: Int)?` (private,
  same file, `AppModel.swift:325`), `AgentState.done` / `.idle` (Task 2's
  import, `CasperCore/Models.swift:3-4`).
- Produces: no signature change to `selectWorkspace(_:)` — behavior-only
  change, test-visible via `AppModel.workspace(id:)?.agentState`.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/CasperUITests/ControlHandlerTests.swift`, right after
`testSelectingWorkspaceClearsItsBubbleWhenKey` (after line 416):

```swift
    func testSelectingDoneWorkspaceCollapsesToIdle() {
        let (model, id) = seededModel()
        model.selectedWorkspaceID = UUID()  // a different workspace is selected first
        model.isWindowKey = { false }
        model.deliverNotification = { _, _, _, _ in }  // mock to avoid UNUserNotificationCenter crash
        _ = model.controlSetAgentState(.done, for: id)
        XCTAssertEqual(model.workspace(id: id)?.agentState, .done)

        model.selectWorkspace(id)
        XCTAssertEqual(model.workspace(id: id)?.agentState, .idle)
    }

    func testSelectingBlockedWorkspaceLeavesStateUnchanged() {
        let (model, id) = seededModel()
        model.selectedWorkspaceID = UUID()
        model.isWindowKey = { false }
        _ = model.controlSetAgentState(.blocked, for: id)

        model.selectWorkspace(id)
        XCTAssertEqual(model.workspace(id: id)?.agentState, .blocked)
    }

    func testSelectingErrorWorkspaceLeavesStateUnchanged() {
        let (model, id) = seededModel()
        model.selectedWorkspaceID = UUID()
        model.isWindowKey = { false }
        _ = model.controlSetAgentState(.error, for: id)

        model.selectWorkspace(id)
        XCTAssertEqual(model.workspace(id: id)?.agentState, .error)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ControlHandlerTests 2>&1 | tail -40`
Expected: `testSelectingDoneWorkspaceCollapsesToIdle` FAILS (`agentState` is
still `.done` after selection); the other two PASS already (regression
guards for the boundary this task must not cross).

- [ ] **Step 3: Implement the collapse in `selectWorkspace`**

In `Sources/CasperUI/AppModel.swift`, change `selectWorkspace(_:)`
(currently lines 477-493) from:

```swift
    func selectWorkspace(_ id: UUID?) {
        selectedWorkspaceID = id
        // Re-arm before the early return so a nil/non-Git selection stops the watcher.
        reconfigureWorktreeWatcher()
        guard let id, let ws = workspace(id: id) else { return }
        // A selected workspace must be visible: expand its owning Space if it was
        // collapsed. Only mutate when actually collapsed, so an already-expanded
        // Space doesn't run a redundant no-op animation.
        if let si = spaces.firstIndex(where: { $0.workspaces.contains { $0.id == id } }),
           spaces[si].isCollapsed {
            withAnimation(.snappy) { spaces[si].isCollapsed = false }
        }
        focusedSurfaceID = LayoutTree.surfaceIDs(ws.layout).first
        focusActiveSurfaceView()
        clearNotificationForFocusedWorkspace()
        persist()
    }
```

to:

```swift
    func selectWorkspace(_ id: UUID?) {
        selectedWorkspaceID = id
        // Re-arm before the early return so a nil/non-Git selection stops the watcher.
        reconfigureWorktreeWatcher()
        guard let id, let ws = workspace(id: id) else { return }
        // A selected workspace must be visible: expand its owning Space if it was
        // collapsed. Only mutate when actually collapsed, so an already-expanded
        // Space doesn't run a redundant no-op animation.
        if let si = spaces.firstIndex(where: { $0.workspaces.contains { $0.id == id } }),
           spaces[si].isCollapsed {
            withAnimation(.snappy) { spaces[si].isCollapsed = false }
        }
        focusedSurfaceID = LayoutTree.surfaceIDs(ws.layout).first
        focusActiveSurfaceView()
        clearNotificationForFocusedWorkspace()
        // A `done` workspace is "finished, not yet seen"; selecting it is
        // exactly the "seen" event, so collapse it back to `idle` here —
        // mirroring the resolver's own seen-gated unlatch
        // (`AgentStateResolver`), but for the explicit-authority path the
        // resolver never runs for (see
        // `.superpowers/themes/agent-state-detection.md` § Authority). Not
        // gated on `isWindowKey()`, unlike the bubble clear above: the
        // resolver's own "seen" test is selection alone. `blocked`/`error`
        // are untouched — selection has no power over them.
        if let at = locate(id), spaces[at.space].workspaces[at.workspace].agentState == .done {
            spaces[at.space].workspaces[at.workspace].agentState = .idle
        }
        persist()
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ControlHandlerTests 2>&1 | tail -40`
Expected: PASS, including all three new tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/CasperUI/AppModel.swift Tests/CasperUITests/ControlHandlerTests.swift
git commit -m "selectWorkspace collapses an explicit done back to idle"
```

---

### Task 4: Full-suite verification + manual check (both repos)

**Files:** none (verification only)

- [ ] **Step 1: Run the full Casper test suite**

Run: `make test 2>&1 | tail -60` (in the `casper` repo)
Expected: PASS, no regressions.

- [ ] **Step 2: Run the full `casper-claude-plugin` test suite**

Run (in the `casper-claude-plugin` repo):

```bash
for t in tests/test_*.sh; do bash "$t"; done
python3 -m unittest discover -s tests -p 'test_*.py' -v
```

Expected: PASS, no regressions.

- [ ] **Step 3: Manual verification via `debug-casper` + a real Claude Code session**

In a Casper terminal workspace, with this plugin installed:

```bash
claude --plugin-dir /path/to/casper-claude-plugin
```

Run one turn, then switch focus away from the workspace (select a different
one, or background the app) before the turn ends. Expected: once the turn's
`Stop` fires, the workspace's sidebar icon shows `done` (`checkmark.circle`),
its attention bubble is armed, and a single passive notification ("Task
finished") arrives silently in Notification Center — no banner, no sound.
Select the workspace again: the bubble clears and the icon reverts to the
ordinary `idle` look.

- [ ] **Step 4: Commit** (only if step 3 uncovered fixes; otherwise skip)
