import AppKit
import GhosttyKit
import XCTest

@testable import CasperGhostty

/// Spike (see `.superpowers/plans/terminal-font-size-persistence.md`,
/// Risk/Spike): confirms `ghostty_surface_inherited_config` reflects a LIVE,
/// runtime-adjusted font size — its documented purpose is building a config
/// for a *new child* split, and whether it also echoes the current surface's
/// own live size was unconfirmed before this test. Uses a real runtime + a
/// real (offscreen) window, exactly like `GhosttyEditingCommandReplayTests`
/// — the `.forTesting()` runtime never creates a surface.
final class GhosttyFontSizeTests: XCTestCase {
    @MainActor
    func testInheritedConfigReflectsLiveFontSizeIncrease() throws {
        let runtime = try GhosttyRuntime()
        let view = GhosttySurfaceView(runtime: runtime, configuration: GhosttySurfaceConfiguration())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view  // triggers viewDidMoveToWindow -> ghostty_surface_new

        // Surface creation can transiently return null and retry; poll until it
        // lands, matching GhosttyEditingCommandReplayTests's precondition guard.
        let deadline = Date().addingTimeInterval(10)
        while view.surface == nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        guard let surface = view.surface else {
            throw XCTSkip("libghostty could not create a surface in this environment")
        }

        let before = surface.currentFontSize()
        surface.bindingAction("increase_font_size:1")
        surface.bindingAction("increase_font_size:1")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let after = surface.currentFontSize()

        XCTAssertGreaterThan(
            after, before,
            "ghostty_surface_inherited_config did not reflect a live font-size " +
            "increase (before: \(before), after: \(after)) — the capture design " +
            "in terminal-font-size-persistence.md needs revisiting; see its " +
            "Alternatives section")
    }
}
