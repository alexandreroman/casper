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
    /// Return ("\r") on a standard US ANSI keyboard.
    private let returnKeyCode: UInt16 = 36

    @MainActor
    func testFocusedSurfaceClaimsControlReturn() throws {
        try withRealSurface { view, _ in
            XCTAssertTrue(
                view.performKeyEquivalent(with: keyEvent("\r", modifiers: [.control], keyCode: returnKeyCode)),
                "a focused surface must claim Ctrl+Return, or AppKit shows the context menu")
        }
    }

    @MainActor
    func testFocusedSurfaceLeavesPlainReturnToKeyDown() throws {
        try withRealSurface { view, _ in
            XCTAssertFalse(
                view.performKeyEquivalent(with: keyEvent("\r", keyCode: returnKeyCode)),
                "a plain Return must fall through to keyDown, not be claimed as an equivalent")
        }
    }

    @MainActor
    func testUnfocusedSurfaceLeavesControlReturnAlone() throws {
        try withRealSurface { view, _ in
            // Hand first responder back to the window itself.
            XCTAssertTrue(view.window?.makeFirstResponder(nil) ?? false)

            XCTAssertFalse(
                view.performKeyEquivalent(with: keyEvent("\r", modifiers: [.control], keyCode: returnKeyCode)),
                "an unfocused surface must not claim Ctrl+Return from whatever is focused")
        }
    }
}
