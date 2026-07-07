# Cmd-hold workspace-switch shortcuts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Holding Cmd for ≥1s reveals a `⌘N` shortcut hint (1-9) in each numbered
sidebar workspace row, in the trailing slot normally occupied by the
notification bubble; releasing Cmd hides it; `Cmd+N` switches to that workspace
at any time, hint visible or not.

**Architecture:** A pure `CommandHoldTracker` state machine turns Cmd
down/up transitions into a delayed "reveal" boolean. A thin
`WorkspaceShortcutKeyMonitor` wraps it with a local `NSEvent` monitor
(`.flagsChanged` for the hold, `.keyDown` for `Cmd+1…9`) and is installed once
from `AppDelegate`. `AppModel` gains the numbering rule (flat order across
visible spaces, capped at 9) and the flag the sidebar reads. `SidebarView`/
`WorkspaceRow` swap the trailing notification bubble for the hint text with a
fade.

**Tech Stack:** Swift 6, SwiftUI (`@Observable`), AppKit `NSEvent`, XCTest.

## Global Constraints

- Swift 6 / SwiftUI, macOS 15+ (project-wide).
- Local `NSEvent` monitor only — no system-wide/global shortcut, no
  Accessibility permission (spec "Non-goals").
- Numbering is one flat list across the whole sidebar (not per-space), capped
  at 9; a collapsed space's workspaces consume zero numbers while hidden
  (spec "Numbering rule").
- `Cmd+N` switches instantly regardless of whether the 1s hold hint has
  appeared yet (spec "Detection & timing").
- The hint replaces `NotificationBubble` in the same trailing slot, animated
  with `.easeInOut(duration: 0.15)`, matching the existing animation family
  already in `WorkspaceRow.swift` (`.easeInOut(duration: 0.8)` pulse,
  `.easeOut(duration: 0.12)` button press) (spec "UI changes").
- Tests follow the existing `AppModelTests.swift` conventions: `@MainActor`
  `XCTestCase`, `Session`/`Space`/`Workspace` literal construction, no new test
  framework or dependency.
- Spec: `docs/superpowers/specs/2026-07-07-workspace-shortcut-hints-design.md`.

---

### Task 1: `AppModel` — shortcut numbering, selection-by-number, hint flag

**Files:**
- Modify: `Sources/CasperUI/AppModel.swift` (add near `allWorkspaces`,
  `Sources/CasperUI/AppModel.swift:232-233`, and near `selectWorkspace(_:)`,
  `Sources/CasperUI/AppModel.swift:412-428`)
- Test: `Tests/CasperUITests/AppModelTests.swift`

**Interfaces:**
- Produces: `AppModel.workspaceShortcutNumbers: [UUID: Int]`,
  `AppModel.selectWorkspace(atShortcutNumber number: Int)`,
  `AppModel.showWorkspaceShortcutHints: Bool` (default `false`) — all consumed
  by Task 3 (monitor) and Task 5 (UI).

- [ ] **Step 1: Write the failing tests**

Add to `Tests/CasperUITests/AppModelTests.swift`, near the other selection
tests (after `testIsWorkspaceGitBackedReflectsOwningSpace`, around line 88):

```swift
    func testWorkspaceShortcutNumbersFollowSidebarOrderAndSkipCollapsedSpaces() {
        let spaceAPrimary = Workspace(name: "a-primary", worktreePath: "/a", branch: "main",
                                       portBase: 40000,
                                       layout: .leaf(Surface(kind: .terminal(cwd: "/a", command: nil))),
                                       kind: .primary)
        let spaceALinked = Workspace(name: "a-linked", worktreePath: "/a-linked", branch: "feature",
                                      portBase: 40010,
                                      layout: .leaf(Surface(kind: .terminal(cwd: "/a-linked", command: nil))),
                                      kind: .linked)
        let spaceA = Space(name: "a", folderPath: "/a", isGitRepo: true,
                            workspaces: [spaceALinked, spaceAPrimary])

        let hiddenOne = Workspace(name: "hidden-1", worktreePath: "/b1", branch: "",
                                   portBase: 40020,
                                   layout: .leaf(Surface(kind: .terminal(cwd: "/b1", command: nil))))
        let hiddenTwo = Workspace(name: "hidden-2", worktreePath: "/b2", branch: "",
                                   portBase: 40030,
                                   layout: .leaf(Surface(kind: .terminal(cwd: "/b2", command: nil))))
        let spaceB = Space(name: "b", folderPath: "/b", isGitRepo: false, isCollapsed: true,
                            workspaces: [hiddenOne, hiddenTwo])

        let spaceCWorkspace = Workspace(name: "c", worktreePath: "/c", branch: "",
                                         portBase: 40040,
                                         layout: .leaf(Surface(kind: .terminal(cwd: "/c", command: nil))))
        let spaceC = Space(name: "c", folderPath: "/c", isGitRepo: false, workspaces: [spaceCWorkspace])

        let session = Session(spaces: [spaceA, spaceB, spaceC])
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store, session: session)

        let numbers = model.workspaceShortcutNumbers
        XCTAssertEqual(numbers[spaceAPrimary.id], 1)
        XCTAssertEqual(numbers[spaceALinked.id], 2)
        XCTAssertNil(numbers[hiddenOne.id])
        XCTAssertNil(numbers[hiddenTwo.id])
        XCTAssertEqual(numbers[spaceCWorkspace.id], 3)
    }

    func testWorkspaceShortcutNumbersCapAtNine() {
        let workspaces = (1...11).map { index in
            Workspace(name: String(format: "w%02d", index), worktreePath: "/w\(index)", branch: "",
                      portBase: 40000 + index * 10,
                      layout: .leaf(Surface(kind: .terminal(cwd: "/w\(index)", command: nil))))
        }
        let space = Space(name: "many", folderPath: "/many", isGitRepo: false, workspaces: workspaces)
        let session = Session(spaces: [space])
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store, session: session)

        let numbers = model.workspaceShortcutNumbers
        XCTAssertEqual(numbers.count, 9)
        let ordered = space.orderedWorkspaces
        for (index, workspace) in ordered.enumerated() {
            if index < 9 {
                XCTAssertEqual(numbers[workspace.id], index + 1)
            } else {
                XCTAssertNil(numbers[workspace.id])
            }
        }
    }

    func testSelectWorkspaceAtShortcutNumberSelectsMatchingWorkspace() {
        let (model, _) = modelWithOnePlainWorkspace()
        model.addSpace(folderURL: URL(fileURLWithPath: "/tmp/second"), probe: { _ in nil })
        let second = model.allWorkspaces.last!.id
        let numberForSecond = model.workspaceShortcutNumbers[second]!

        model.selectWorkspace(atShortcutNumber: numberForSecond)

        XCTAssertEqual(model.selectedWorkspaceID, second)
    }

    func testSelectWorkspaceAtShortcutNumberOutOfRangeIsNoOp() {
        let (model, workspaceID) = modelWithOnePlainWorkspace()
        model.selectedWorkspaceID = workspaceID

        model.selectWorkspace(atShortcutNumber: 7)

        XCTAssertEqual(model.selectedWorkspaceID, workspaceID)
    }

    func testShowWorkspaceShortcutHintsDefaultsFalse() {
        let (model, _) = modelWithOnePlainWorkspace()
        XCTAssertFalse(model.showWorkspaceShortcutHints)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CasperUITests.AppModelTests`
Expected: FAIL — `workspaceShortcutNumbers`, `selectWorkspace(atShortcutNumber:)`,
and `showWorkspaceShortcutHints` do not exist yet (compile error).

- [ ] **Step 3: Implement in `AppModel.swift`**

Add directly below `allWorkspaces` (`Sources/CasperUI/AppModel.swift:232-233`):

```swift
    /// Maps eligible workspaces to their `Cmd+N` shortcut (1-9), following
    /// sidebar display order: `spaces` in list order, collapsed spaces
    /// skipped entirely (their workspaces aren't visible, so they get no
    /// shortcut while hidden), each visible space's workspaces in
    /// `orderedWorkspaces` order. Feeds both the sidebar hint label and
    /// `selectWorkspace(atShortcutNumber:)` — the two can never drift apart
    /// since they share this one lookup.
    var workspaceShortcutNumbers: [UUID: Int] {
        var numbers: [UUID: Int] = [:]
        var next = 1
        for space in spaces where !space.isCollapsed {
            for workspace in space.orderedWorkspaces {
                guard next <= 9 else { return numbers }
                numbers[workspace.id] = next
                next += 1
            }
        }
        return numbers
    }

    /// Whether the sidebar should show the `Cmd+N` shortcut hint in place of
    /// the notification bubble. Set by `WorkspaceShortcutKeyMonitor` while
    /// Cmd is held past the reveal delay.
    var showWorkspaceShortcutHints: Bool = false
```

Add directly below `selectWorkspace(_:)` (`Sources/CasperUI/AppModel.swift:412-428`):

```swift
    /// Switches to the workspace at `number` (1-9) in `workspaceShortcutNumbers`
    /// order. A number with no matching workspace (e.g. `Cmd+7` with only four
    /// workspaces) is a no-op.
    func selectWorkspace(atShortcutNumber number: Int) {
        guard let match = workspaceShortcutNumbers.first(where: { $0.value == number })?.key else { return }
        selectWorkspace(match)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CasperUITests.AppModelTests`
Expected: PASS (all tests in the file, including the 5 new ones).

- [ ] **Step 5: Commit**

```bash
git add Sources/CasperUI/AppModel.swift Tests/CasperUITests/AppModelTests.swift
git commit -m "Add workspace shortcut numbering and Cmd+N selection to AppModel"
```

---

### Task 2: `CommandHoldTracker` — pure hold-timing state machine

**Files:**
- Create: `Sources/CasperUI/CommandHoldTracker.swift`
- Test: `Tests/CasperUITests/CommandHoldTrackerTests.swift`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `HoldTimerToken` protocol, `CommandHoldTracker` (init, `commandKeyDown()`,
  `commandKeyUp()`) — consumed by Task 3.

- [ ] **Step 1: Write the failing tests**

Create `Tests/CasperUITests/CommandHoldTrackerTests.swift`:

```swift
import XCTest
@testable import CasperUI

@MainActor
final class CommandHoldTrackerTests: XCTestCase {
    private final class FakeToken: HoldTimerToken {
        private(set) var cancelled = false
        func cancel() { cancelled = true }
    }

    func testRevealsAfterTimerFires() {
        var revealed: [Bool] = []
        var firedClosure: (() -> Void)?
        let tracker = CommandHoldTracker(
            holdDuration: 1.0,
            scheduleTimer: { interval, fire in
                XCTAssertEqual(interval, 1.0)
                firedClosure = fire
                return FakeToken()
            },
            onRevealChange: { revealed.append($0) }
        )

        tracker.commandKeyDown()
        XCTAssertTrue(revealed.isEmpty, "must not reveal before the timer fires")
        firedClosure?()
        XCTAssertEqual(revealed, [true])
    }

    func testReleasingBeforeTimerFiresCancelsAndNeverReveals() {
        var revealed: [Bool] = []
        var cancelledToken: FakeToken?
        let tracker = CommandHoldTracker(
            holdDuration: 1.0,
            scheduleTimer: { _, _ in
                let token = FakeToken()
                cancelledToken = token
                return token
            },
            onRevealChange: { revealed.append($0) }
        )

        tracker.commandKeyDown()
        tracker.commandKeyUp()

        XCTAssertEqual(cancelledToken?.cancelled, true)
        XCTAssertEqual(revealed, [false])
    }

    func testReleasingAfterRevealHidesHints() {
        var revealed: [Bool] = []
        var firedClosure: (() -> Void)?
        let tracker = CommandHoldTracker(
            holdDuration: 1.0,
            scheduleTimer: { _, fire in
                firedClosure = fire
                return FakeToken()
            },
            onRevealChange: { revealed.append($0) }
        )

        tracker.commandKeyDown()
        firedClosure?()
        tracker.commandKeyUp()

        XCTAssertEqual(revealed, [true, false])
    }

    func testSecondKeyDownWhileTimerPendingDoesNotRestartTimer() {
        var scheduleCount = 0
        let tracker = CommandHoldTracker(
            holdDuration: 1.0,
            scheduleTimer: { _, _ in
                scheduleCount += 1
                return FakeToken()
            },
            onRevealChange: { _ in }
        )

        tracker.commandKeyDown()
        tracker.commandKeyDown()

        XCTAssertEqual(scheduleCount, 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CasperUITests.CommandHoldTrackerTests`
Expected: FAIL — `CommandHoldTracker`/`HoldTimerToken` do not exist yet
(compile error).

- [ ] **Step 3: Implement `CommandHoldTracker.swift`**

Create `Sources/CasperUI/CommandHoldTracker.swift`:

```swift
import Foundation

/// A cancellable handle for a scheduled reveal timer, abstracting `Timer` so
/// `CommandHoldTracker` is testable without a real delay.
protocol HoldTimerToken: AnyObject {
    func cancel()
}

extension Timer: HoldTimerToken {
    func cancel() { invalidate() }
}

/// Turns Cmd key down/up transitions into a delayed "reveal" boolean: Cmd
/// must stay held for `holdDuration` before `onRevealChange(true)` fires;
/// releasing Cmd at any point — before or after the reveal — immediately
/// fires `onRevealChange(false)` and cancels any pending timer. Pure state
/// machine, no `NSEvent` dependency, so it's testable with an injected fake
/// scheduler (see `CommandHoldTrackerTests`).
@MainActor
final class CommandHoldTracker {
    private let holdDuration: TimeInterval
    private let scheduleTimer: (TimeInterval, @escaping () -> Void) -> HoldTimerToken
    private let onRevealChange: (Bool) -> Void
    private var pendingToken: HoldTimerToken?

    init(
        holdDuration: TimeInterval = 1.0,
        scheduleTimer: @escaping (TimeInterval, @escaping () -> Void) -> HoldTimerToken = { interval, fire in
            let timer = Timer(timeInterval: interval, repeats: false) { _ in fire() }
            // `.common` so the timer still fires while the run loop is in
            // event-tracking mode (e.g. a context menu is open).
            RunLoop.main.add(timer, forMode: .common)
            return timer
        },
        onRevealChange: @escaping (Bool) -> Void
    ) {
        self.holdDuration = holdDuration
        self.scheduleTimer = scheduleTimer
        self.onRevealChange = onRevealChange
    }

    func commandKeyDown() {
        guard pendingToken == nil else { return }
        pendingToken = scheduleTimer(holdDuration) { [weak self] in
            self?.pendingToken = nil
            self?.onRevealChange(true)
        }
    }

    func commandKeyUp() {
        pendingToken?.cancel()
        pendingToken = nil
        onRevealChange(false)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CasperUITests.CommandHoldTrackerTests`
Expected: PASS (all 4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CasperUI/CommandHoldTracker.swift Tests/CasperUITests/CommandHoldTrackerTests.swift
git commit -m "Add CommandHoldTracker: pure Cmd-hold-delay state machine"
```

---

### Task 3: `WorkspaceShortcutKeyMonitor` — NSEvent glue

**Files:**
- Create: `Sources/CasperUI/WorkspaceShortcutKeyMonitor.swift`
- Test: `Tests/CasperUITests/WorkspaceShortcutKeyMonitorTests.swift`

**Interfaces:**
- Consumes: `AppModel.workspaceShortcutNumbers`, `AppModel.selectWorkspace(atShortcutNumber:)`,
  `AppModel.showWorkspaceShortcutHints` (Task 1); `CommandHoldTracker` (Task 2).
- Produces: `WorkspaceShortcutKeyMonitor(model:holdDuration:)`, `.start()`,
  `.handle(_:) -> NSEvent?` — `.start()` consumed by Task 4.

- [ ] **Step 1: Write the failing tests**

Create `Tests/CasperUITests/WorkspaceShortcutKeyMonitorTests.swift`:

```swift
import AppKit
import XCTest
import CasperCore
@testable import CasperUI

@MainActor
final class WorkspaceShortcutKeyMonitorTests: XCTestCase {
    private func makeStore() -> SessionStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("casper-test-\(UUID().uuidString).json")
        return SessionStore(fileURL: url)
    }

    private func flagsChangedEvent(command: Bool) -> NSEvent {
        NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: command ? [.command] : [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 0
        )!
    }

    private func keyDownEvent(
        characters: String, command: Bool, extraModifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        var flags = extraModifiers
        if command { flags.insert(.command) }
        return NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 0
        )!
    }

    func testCmdDigitSelectsWorkspaceAndConsumesEvent() {
        let session = Session(spaces: [
            Space(name: "a", folderPath: "/a", isGitRepo: false, workspaces: [
                Workspace(name: "a", worktreePath: "/a", branch: "", portBase: 40000,
                          layout: .leaf(Surface(kind: .terminal(cwd: "/a", command: nil)))),
            ]),
        ])
        let model = AppModel(sessionStore: makeStore(), session: session)
        let target = model.allWorkspaces[0].id
        model.selectedWorkspaceID = nil
        let monitor = WorkspaceShortcutKeyMonitor(model: model)

        let passthrough = monitor.handle(keyDownEvent(characters: "1", command: true))

        XCTAssertNil(passthrough, "a handled Cmd+digit must consume the event")
        XCTAssertEqual(model.selectedWorkspaceID, target)
    }

    func testCmdShiftDigitIsIgnored() {
        let model = AppModel(sessionStore: makeStore())
        let monitor = WorkspaceShortcutKeyMonitor(model: model)

        let passthrough = monitor.handle(keyDownEvent(characters: "1", command: true, extraModifiers: .shift))

        XCTAssertNotNil(passthrough, "Cmd+Shift+digit is a different shortcut and must pass through")
    }

    func testHoldingCommandRevealsHintsAfterDuration() {
        let model = AppModel(sessionStore: makeStore())
        let monitor = WorkspaceShortcutKeyMonitor(model: model, holdDuration: 0.05)
        _ = monitor.handle(flagsChangedEvent(command: true))

        let expectation = expectation(description: "hints revealed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertTrue(model.showWorkspaceShortcutHints)
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1.0)
    }

    func testReleasingCommandHidesHints() {
        let model = AppModel(sessionStore: makeStore())
        let monitor = WorkspaceShortcutKeyMonitor(model: model, holdDuration: 0.05)
        _ = monitor.handle(flagsChangedEvent(command: true))
        _ = monitor.handle(flagsChangedEvent(command: false))

        XCTAssertFalse(model.showWorkspaceShortcutHints)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CasperUITests.WorkspaceShortcutKeyMonitorTests`
Expected: FAIL — `WorkspaceShortcutKeyMonitor` does not exist yet (compile error).

- [ ] **Step 3: Implement `WorkspaceShortcutKeyMonitor.swift`**

Create `Sources/CasperUI/WorkspaceShortcutKeyMonitor.swift`:

```swift
import AppKit
import SwiftUI

/// Watches for Cmd being held ≥1s to reveal the sidebar's `Cmd+N` shortcut
/// hints (see `WorkspaceRow`), and handles `Cmd+1…9` itself so the workspace
/// switch works even before the hint appears. Installed once from
/// `AppDelegate.applicationDidFinishLaunching`, the same place `FileMenu`'s
/// menu wiring happens — a local (not global) `NSEvent` monitor, so this only
/// fires while a Casper window is key and needs no Accessibility permission.
@MainActor
final class WorkspaceShortcutKeyMonitor {
    private let model: AppModel
    private let tracker: CommandHoldTracker
    private var eventMonitor: Any?

    init(model: AppModel, holdDuration: TimeInterval = 1.0) {
        self.model = model
        self.tracker = CommandHoldTracker(holdDuration: holdDuration) { show in
            withAnimation(.easeInOut(duration: 0.15)) {
                model.showWorkspaceShortcutHints = show
            }
        }
    }

    /// Installs the local event monitor. Call once; the monitor is removed in
    /// `deinit`.
    func start() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            self?.handle(event)
        }
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    /// Returns the event to let it keep propagating, or `nil` to consume it
    /// (only for a handled `Cmd+digit`). Not `private` so tests can drive it
    /// directly with synthetic `NSEvent`s instead of going through a real
    /// event monitor.
    func handle(_ event: NSEvent) -> NSEvent? {
        // Only bare Cmd (no Shift/Option/Control) triggers the hold-reveal
        // and Cmd+digit switch, so this never fires mid-combo with an
        // unrelated shortcut like Cmd+Shift+D ("Split down", `FileMenu.swift`).
        let relevantFlags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch event.type {
        case .flagsChanged:
            if relevantFlags == .command {
                tracker.commandKeyDown()
            } else {
                tracker.commandKeyUp()
            }
            return event
        case .keyDown:
            guard
                relevantFlags == .command,
                let characters = event.charactersIgnoringModifiers,
                characters.count == 1,
                let digit = Int(characters),
                (1...9).contains(digit)
            else {
                return event
            }
            model.selectWorkspace(atShortcutNumber: digit)
            return nil
        default:
            return event
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CasperUITests.WorkspaceShortcutKeyMonitorTests`
Expected: PASS (all 4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CasperUI/WorkspaceShortcutKeyMonitor.swift Tests/CasperUITests/WorkspaceShortcutKeyMonitorTests.swift
git commit -m "Add WorkspaceShortcutKeyMonitor: Cmd-hold hint + Cmd+N switch"
```

---

### Task 4: Wire the monitor into `AppDelegate`

**Files:**
- Modify: `Sources/CasperUI/AppDelegate.swift:10-25`

**Interfaces:**
- Consumes: `WorkspaceShortcutKeyMonitor(model:)`, `.start()` (Task 3).
- Produces: nothing new consumed by later tasks — this is app-lifecycle
  wiring, matching the existing `controlServer`/`debugServer` pattern in the
  same file, which has no dedicated unit test.

- [ ] **Step 1: Add the stored property**

In `Sources/CasperUI/AppDelegate.swift`, add alongside the other stored
properties (`Sources/CasperUI/AppDelegate.swift:11-15`):

```swift
    private var controlServer: ControlServer?
    private var keyWindowObserver: NSObjectProtocol?
    private var workspaceShortcutMonitor: WorkspaceShortcutKeyMonitor?
    #if DEBUG
    private var debugServer: DebugServer?
    #endif
```

- [ ] **Step 2: Start the monitor in `applicationDidFinishLaunching`**

Right after the menu wiring (`Sources/CasperUI/AppDelegate.swift:24-25`):

```swift
        NSApp.mainMenu = buildMainMenu()
        NSApp.mainMenu?.insertItem(model.fileMenuItem(), at: 1)

        let shortcutMonitor = WorkspaceShortcutKeyMonitor(model: model)
        shortcutMonitor.start()
        workspaceShortcutMonitor = shortcutMonitor
```

- [ ] **Step 3: Build to confirm it compiles**

Run: `swift build`
Expected: build succeeds with no errors.

- [ ] **Step 4: Manual verification**

Run: `make dev`. Hold Cmd for about a second and confirm nothing crashes and
the app launches normally (the visible hint itself lands in Task 5 — this step
only confirms the monitor is wired up without breaking startup).

- [ ] **Step 5: Commit**

```bash
git add Sources/CasperUI/AppDelegate.swift
git commit -m "Wire WorkspaceShortcutKeyMonitor into AppDelegate startup"
```

---

### Task 5: Sidebar UI — swap the notification bubble for the shortcut hint

**Files:**
- Modify: `Sources/CasperUI/SidebarView.swift:37-56`
- Modify: `Sources/CasperUI/WorkspaceRow.swift:11-138`

**Interfaces:**
- Consumes: `AppModel.workspaceShortcutNumbers`, `AppModel.showWorkspaceShortcutHints`
  (Task 1).
- Produces: nothing consumed by later tasks (leaf UI change).

- [ ] **Step 1: Pass the number and hint flag from `SidebarView`**

In `Sources/CasperUI/SidebarView.swift`, change `row(for:in:)`
(`Sources/CasperUI/SidebarView.swift:37-56`):

```swift
    private func row(for workspace: Workspace, in space: Space) -> some View {
        WorkspaceRow(
            workspace: workspace,
            isSelected: workspace.id == model.selectedWorkspaceID,
            isGitRepo: space.isGitRepo,
            shortcutNumber: model.workspaceShortcutNumbers[workspace.id],
            showShortcutHints: model.showWorkspaceShortcutHints
        )
        .onTapGesture { model.selectWorkspace(workspace.id) }
        .contextMenu {
            if workspace.kind == .linked {
                if let base = workspace.baseBranch, !base.isEmpty {
                    Button("Close workspace…") {
                        model.presentCloseWorkspaceConfirmation(id: workspace.id)
                    }
                }
                Button("Delete workspace…", role: .destructive) {
                    model.presentDeleteWorkspaceConfirmation(id: workspace.id)
                }
            }
        }
    }
```

- [ ] **Step 2: Add the fields and swap in `WorkspaceRow`**

In `Sources/CasperUI/WorkspaceRow.swift`, add the two new fields to the struct
(`Sources/CasperUI/WorkspaceRow.swift:11-16`):

```swift
struct WorkspaceRow: View {
    let workspace: Workspace
    let isSelected: Bool
    let isGitRepo: Bool
    let shortcutNumber: Int?
    let showShortcutHints: Bool

    @State private var isHovered = false
```

Replace the trailing notification bubble (`Sources/CasperUI/WorkspaceRow.swift:30-31`):

```swift
                NotificationBubble(on: workspace.pendingNotification, isSelected: isSelected)
                    .frame(width: 20)
```

with:

```swift
                Group {
                    if showShortcutHints, let shortcutNumber {
                        WorkspaceShortcutHint(number: shortcutNumber, isSelected: isSelected)
                            .transition(.opacity)
                    } else {
                        NotificationBubble(on: workspace.pendingNotification, isSelected: isSelected)
                            .transition(.opacity)
                    }
                }
                .frame(width: 20)
                .animation(.easeInOut(duration: 0.15), value: showShortcutHints)
```

Add the new view next to `NotificationBubble`
(`Sources/CasperUI/WorkspaceRow.swift:116-119`, directly above it):

```swift
/// The `Cmd+N` hint shown in the notification bubble's slot while Cmd is held
/// past the reveal delay (see `WorkspaceShortcutKeyMonitor`). Selection-aware,
/// matching every other trailing/leading glyph in this row.
private struct WorkspaceShortcutHint: View {
    let number: Int
    let isSelected: Bool

    var body: some View {
        Text("⌘\(number)")
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(isSelected ? Color.white : Color.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: build succeeds. (No new unit test here — there is no existing
precedent in this repo for testing `SidebarView`/`WorkspaceRow` SwiftUI
rendering directly; `AppModelTests` already covers the data this view reads.)

- [ ] **Step 4: Manual verification**

Run: `make dev`. With at least 2-3 workspaces open (some in a collapsed
space), hold Cmd for about a second and confirm:
- the first 9 *visible* rows fade in a `⌘N` label where the notification dot
  normally sits, in sidebar top-to-bottom order;
- a workspace in a collapsed space shows no hint;
- releasing Cmd fades the hints back out to the normal notification bubble;
- pressing `Cmd+N` (both before and after the 1s hint appears) switches to
  the corresponding workspace;
- a workspace with a pending notification still shows its pulsing dot when
  Cmd is not held.

- [ ] **Step 5: Commit**

```bash
git add Sources/CasperUI/SidebarView.swift Sources/CasperUI/WorkspaceRow.swift
git commit -m "Show Cmd+N shortcut hints in the sidebar while Cmd is held"
```
