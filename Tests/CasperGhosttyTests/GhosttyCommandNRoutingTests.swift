import AppKit
import XCTest
import CasperTestSupport

@testable import CasperGhostty

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
            // ⌘N: "n" is keyCode 45 on a standard US ANSI keyboard.
            let consumed = view.performKeyEquivalent(with: keyEvent("n", modifiers: [.command], keyCode: 45))
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
