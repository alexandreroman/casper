import AppKit
import XCTest
import CasperCore
import Observation
@testable import CasperUI

@MainActor
final class WorkspaceShortcutKeyMonitorTests: XCTestCase {
    private func makeStore() -> SessionStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("casper-test-\(UUID().uuidString).json")
        return SessionStore(fileURL: url)
    }

    private func flagsChangedEvent(
        command: Bool, extraModifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        var flags = extraModifiers
        if command { flags.insert(.command) }
        return NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: flags,
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
        keyCode: UInt16, command: Bool, characters: String = "",
        extraModifiers: NSEvent.ModifierFlags = []
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
            keyCode: keyCode
        )!
    }

    func testCmdDigitSelectsWorkspaceAndConsumesEvent() {
        let session = Session(spaces: [
            Space(name: "a", folderPath: "/a", isGitRepo: false, workspaces: [
                Workspace(name: "a", worktreePath: "/a", branch: "", portBase: 40000,
                          layout: .leaf(Surface(kind: .terminal(cwd: "/a")))),
            ]),
        ])
        let model = AppModel(sessionStore: makeStore(), session: session)
        let target = model.allWorkspaces[0].id
        model.selectedWorkspaceID = nil
        let monitor = WorkspaceShortcutKeyMonitor(model: model)

        let passthrough = monitor.handle(keyDownEvent(keyCode: 0x12, command: true))

        XCTAssertNil(passthrough, "a handled Cmd+digit must consume the event")
        XCTAssertEqual(model.selectedWorkspaceID, target)
    }

    func testCmdShiftDigitIsIgnored() {
        let model = AppModel(sessionStore: makeStore())
        let monitor = WorkspaceShortcutKeyMonitor(model: model)

        let passthrough = monitor.handle(keyDownEvent(keyCode: 0x12, command: true, extraModifiers: .shift))

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

    /// Pressing Shift while Cmd is held — the start of any Cmd+Shift shortcut, e.g.
    /// Cmd+Shift+D ("Split Down") — releases a hold that never revealed anything. The
    /// hints flag is already false, so nothing may write it: an unconditional write to
    /// an `@Observable` property notifies every sidebar row for no change.
    ///
    /// `withObservationTracking` proves the absence of that write with no test-only
    /// instrumentation in production code (the `observation-tracking-guard-tests` note).
    func testAbandonedCommandHoldDoesNotWriteTheHintsFlag() {
        let model = AppModel(sessionStore: makeStore())
        // Long hold so the reveal timer is still pending when Shift arrives.
        let monitor = WorkspaceShortcutKeyMonitor(model: model, holdDuration: 10)
        _ = monitor.handle(flagsChangedEvent(command: true))
        XCTAssertFalse(model.showWorkspaceShortcutHints)

        // `onChange` is `@Sendable`, even though this test only ever touches the model
        // on the main actor it also runs on — the same rationale the codebase already
        // accepts for `nonisolated(unsafe)` elsewhere.
        nonisolated(unsafe) var wrote = false
        withObservationTracking {
            _ = model.showWorkspaceShortcutHints
        } onChange: {
            wrote = true
        }

        _ = monitor.handle(flagsChangedEvent(command: true, extraModifiers: .shift))

        XCTAssertFalse(wrote, "releasing a hold that never revealed must not write the flag")
        XCTAssertFalse(model.showWorkspaceShortcutHints)
    }

    func testCmdDigitWithNoMatchingWorkspacePassesThroughUnconsumed() {
        let session = Session(spaces: [
            Space(name: "a", folderPath: "/a", isGitRepo: false, workspaces: [
                Workspace(name: "a", worktreePath: "/a", branch: "", portBase: 40000,
                          layout: .leaf(Surface(kind: .terminal(cwd: "/a")))),
            ]),
        ])
        let model = AppModel(sessionStore: makeStore(), session: session)
        let previousSelection = model.selectedWorkspaceID
        let monitor = WorkspaceShortcutKeyMonitor(model: model)

        let passthrough = monitor.handle(keyDownEvent(keyCode: 0x19, command: true))

        XCTAssertNotNil(passthrough, "an unmapped Cmd+digit must not be consumed")
        XCTAssertEqual(model.selectedWorkspaceID, previousSelection)
    }

    func testCmdDigitMatchesPhysicalKeyRegardlessOfLayoutCharacters() {
        let session = Session(spaces: [
            Space(name: "a", folderPath: "/a", isGitRepo: false, workspaces: [
                Workspace(name: "a", worktreePath: "/a", branch: "", portBase: 40000,
                          layout: .leaf(Surface(kind: .terminal(cwd: "/a")))),
            ]),
        ])
        let model = AppModel(sessionStore: makeStore(), session: session)
        let target = model.allWorkspaces[0].id
        model.selectedWorkspaceID = nil
        let monitor = WorkspaceShortcutKeyMonitor(model: model)

        // Physical "1" key (0x12) reported as "&" — what an AZERTY layout emits
        // for that key when Shift is not held. Must still switch workspaces.
        let passthrough = monitor.handle(keyDownEvent(keyCode: 0x12, command: true, characters: "&"))

        XCTAssertNil(passthrough, "the physical digit key must switch regardless of the layout's character")
        XCTAssertEqual(model.selectedWorkspaceID, target)
    }

    func testCmdNumpadDigitSelectsWorkspaceAndConsumesEvent() {
        let session = Session(spaces: [
            Space(name: "a", folderPath: "/a", isGitRepo: false, workspaces: [
                Workspace(name: "a", worktreePath: "/a", branch: "", portBase: 40000,
                          layout: .leaf(Surface(kind: .terminal(cwd: "/a")))),
            ]),
        ])
        let model = AppModel(sessionStore: makeStore(), session: session)
        let target = model.allWorkspaces[0].id
        model.selectedWorkspaceID = nil
        let monitor = WorkspaceShortcutKeyMonitor(model: model)

        // Numpad "1" (kVK_ANSI_Keypad1, 0x53) switches like the top-row "1".
        let passthrough = monitor.handle(keyDownEvent(keyCode: 0x53, command: true, characters: "1"))

        XCTAssertNil(passthrough, "a handled Cmd+numpad digit must consume the event")
        XCTAssertEqual(model.selectedWorkspaceID, target)
    }

    func testResignActiveHidesHintsEvenAfterExternalCommandRelease() {
        let model = AppModel(sessionStore: makeStore())
        let monitor = WorkspaceShortcutKeyMonitor(model: model, holdDuration: 0.05)
        monitor.start()
        _ = monitor.handle(flagsChangedEvent(command: true))

        let revealed = expectation(description: "hints revealed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertTrue(model.showWorkspaceShortcutHints)
            revealed.fulfill()
        }
        wait(for: [revealed], timeout: 1.0)

        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)

        let hidden = expectation(description: "hints hidden after resigning active, even without a matching flagsChanged release")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertFalse(model.showWorkspaceShortcutHints)
            hidden.fulfill()
        }
        wait(for: [hidden], timeout: 1.0)
    }
}
