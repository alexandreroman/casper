import AppKit
import XCTest

@testable import CasperGhostty

/// Regression test for Ctrl+Return opening the pane's context menu instead of reaching
/// the terminal program (Claude Code uses it to force-send a message).
///
/// AppKit treats Ctrl+Return as a context-menu keyboard equivalent, so a focused
/// surface must claim it in `performKeyEquivalent` — the method AppKit calls for a real
/// keypress — and stop the key-equivalent pass there. When the surface is not focused
/// it must leave the key alone.
///
/// Runs on the shared `withRealSurface` harness — the `.forTesting()` runtime never
/// creates a surface, and without one `performKeyEquivalent` returns false before any
/// of the checks under test, which would make the unfocused assertion vacuous.
final class GhosttyControlReturnTests: XCTestCase {
    @MainActor
    func testFocusedSurfaceClaimsControlReturn() throws {
        try withRealSurface { view, _ in
            // Let the surface reach a live shell before typing at it.
            settle(0.6)

            XCTAssertTrue(
                view.performKeyEquivalent(with: try returnKeyDown(modifierFlags: [.control])),
                "a focused surface must claim Ctrl+Return, or AppKit shows the context menu")
        }
    }

    @MainActor
    func testFocusedSurfaceLeavesPlainReturnToKeyDown() throws {
        try withRealSurface { view, _ in
            settle(0.6)

            XCTAssertFalse(
                view.performKeyEquivalent(with: try returnKeyDown(modifierFlags: [])),
                "a plain Return must fall through to keyDown, not be claimed as an equivalent")
        }
    }

    @MainActor
    func testUnfocusedSurfaceLeavesControlReturnAlone() throws {
        try withRealSurface { view, _ in
            settle(0.6)
            // Hand first responder back to the window itself.
            XCTAssertTrue(view.window?.makeFirstResponder(nil) ?? false)

            XCTAssertFalse(
                view.performKeyEquivalent(with: try returnKeyDown(modifierFlags: [.control])),
                "an unfocused surface must not claim Ctrl+Return from whatever is focused")
        }
    }

    /// A Return key-down: "\r" is keyCode 36 on a standard US ANSI keyboard.
    private func returnKeyDown(modifierFlags: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifierFlags, timestamp: 0,
            windowNumber: 0, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    }
}
