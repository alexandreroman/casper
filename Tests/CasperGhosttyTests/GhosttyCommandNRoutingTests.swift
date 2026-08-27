import AppKit
import XCTest

@testable import CasperGhostty

/// Records the app-level actions the runtime dispatches, and claims them all —
/// standing in for `CasperUI.LayoutActionHandler`, which this module cannot see.
private final class RecordingActionHandler: GhosttyActionHandler {
    private(set) var actions: [GhosttyAction] = []

    func handle(_ action: GhosttyAction) -> Bool {
        actions.append(action)
        return true
    }
}

/// Regression test for a shortcut that a focused terminal used to swallow.
///
/// `performKeyEquivalent` runs ahead of the main menu and forwards every ⌘ combo to
/// libghostty, returning its consumed flag — and libghostty's default macOS keybinds
/// bind ⌘N to `new_window`. So the app never gets to choose between the terminal and
/// the menu item: the keystroke is claimed here or it is lost, and the only way to
/// make it act is to handle the `.newWindow` action it decodes to (CasperUI maps it
/// onto "New Space…"). This pins the delivery half of that: a genuine ⌘N `NSEvent`,
/// through the method AppKit calls for a real keypress, on a live surface.
///
/// Runs on the shared `withRealSurface` harness — the `.forTesting()` runtime never
/// creates a surface, and without one `performKeyEquivalent` returns before it
/// reaches libghostty at all.
final class GhosttyCommandNRoutingTests: XCTestCase {
    @MainActor
    func testCommandNReachesTheActionHandlerAsNewWindow() throws {
        let handler = RecordingActionHandler()
        let makeView = { (runtime: GhosttyRuntime) in
            runtime.actionHandler = handler
            return GhosttySurfaceView(runtime: runtime, configuration: GhosttySurfaceConfiguration())
        }

        try withRealSurface(makeView: makeView) { view, _ in
            // Let the surface reach a live shell before typing at it.
            settle(0.6)

            // ⌘N: "n" is keyCode 45 on a standard US ANSI keyboard.
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                windowNumber: 0, context: nil, characters: "n",
                charactersIgnoringModifiers: "n", isARepeat: false, keyCode: 45)!
            let consumed = view.performKeyEquivalent(with: event)
            settle(0.4)

            XCTAssertEqual(
                handler.actions, [.newWindow],
                "⌘N did not arrive as a .newWindow action, so nothing downstream can act on it")
            XCTAssertTrue(
                consumed,
                "the surface must report ⌘N consumed — a handled shortcut that also falls " +
                "through to the menu would run twice")
        }
    }
}
