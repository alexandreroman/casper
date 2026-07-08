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

    /// `increaseFontSize` must read the new size back and forward it (with the
    /// surface's own id) to `onFontSizeChange`. Real runtime + real window,
    /// same precondition-skip pattern as the spike test above.
    @MainActor
    func testIncreaseFontSizeReportsChangedSizeToClosure() throws {
        let runtime = try GhosttyRuntime()
        var reported: (UUID, Float)?
        let surfaceID = UUID()
        let view = GhosttySurfaceView(
            runtime: runtime, configuration: GhosttySurfaceConfiguration(), surfaceID: surfaceID,
            onFontSizeChange: { id, size in reported = (id, size) })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view

        let deadline = Date().addingTimeInterval(10)
        while view.surface == nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        guard view.surface != nil else {
            throw XCTSkip("libghostty could not create a surface in this environment")
        }

        view.increaseFontSize(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        let (reportedID, reportedSize) = try XCTUnwrap(reported)
        XCTAssertEqual(reportedID, surfaceID)
        XCTAssertGreaterThan(reportedSize, 0)
    }

    /// Without a live surface (the `.forTesting()` runtime never creates one),
    /// the font-size actions must not invoke the closure at all — deterministic
    /// and surfaceless, no window/polling needed.
    @MainActor
    func testFontSizeChangeClosureDoesNotFireWithoutALiveSurface() {
        var firedCount = 0
        let view = GhosttySurfaceView(
            runtime: .forTesting(), configuration: GhosttySurfaceConfiguration(),
            onFontSizeChange: { _, _ in firedCount += 1 })
        view.increaseFontSize(nil)
        view.decreaseFontSize(nil)
        view.resetFontSize(nil)
        XCTAssertEqual(firedCount, 0)
    }
}
