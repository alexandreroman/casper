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
