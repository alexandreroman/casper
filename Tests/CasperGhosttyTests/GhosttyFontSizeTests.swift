import AppKit
import GhosttyKit
import XCTest
import CasperTestSupport

@testable import CasperGhostty

/// The standing guard for the font-size read-back: pins that
/// `ghostty_surface_inherited_config` reports a surface's LIVE, runtime-adjusted
/// font size, not the size it was created with. That is a use its documented
/// purpose (building a config for a *new child* split) only implies, and font-size
/// persistence rests on it; if this fails, read
/// [[ghostty-inherited-config-font-size]]. Runs on the shared `withRealSurface`
/// harness — the `.forTesting()` runtime never creates a surface.
final class GhosttyFontSizeTests: XCTestCase {
    @MainActor
    func testInheritedConfigReflectsLiveFontSizeIncrease() throws {
        try withRealSurface { _, surface in
            let before = surface.currentFontSize()
            surface.bindingAction("increase_font_size:1")
            surface.bindingAction("increase_font_size:1")
            settle(0.3)
            let after = surface.currentFontSize()

            XCTAssertGreaterThan(
                after, before,
                "ghostty_surface_inherited_config did not reflect a live font-size " +
                "increase (before: \(before), after: \(after)) — the capture design " +
                "needs revisiting; see the ghostty-inherited-config-font-size " +
                "memory note for the recorded alternative")
        }
    }

    /// Without a live surface (the `.forTesting()` runtime never creates one), a
    /// font-size keypress must not invoke the closure at all — deterministic and
    /// surfaceless, no window/polling needed.
    @MainActor
    func testFontSizeChangeClosureDoesNotFireWithoutALiveSurface() {
        var firedCount = 0
        let view = GhosttySurfaceView(
            runtime: .forTesting(), configuration: GhosttySurfaceConfiguration(),
            onFontSizeChange: { _, _ in firedCount += 1 })

        XCTAssertFalse(view.performKeyEquivalent(with: commandEqual()))

        XCTAssertEqual(firedCount, 0)
    }

    /// Regression test for the actual bug: a font-size change libghostty resolves
    /// internally from a REAL Cmd-combo keypress must still be captured and
    /// reported (with the surface's own id) to `onFontSizeChange`. Constructs a
    /// genuine Cmd+Equal NSEvent and drives it through `performKeyEquivalent` —
    /// the exact method AppKit calls for a real physical Cmd+ keypress.
    @MainActor
    func testRealCommandEqualKeypressThroughPerformKeyEquivalentReportsChange() throws {
        var reported: (UUID, Float)?
        let surfaceID = UUID()
        let makeView = { (runtime: GhosttyRuntime) in
            GhosttySurfaceView(
                runtime: runtime, configuration: GhosttySurfaceConfiguration(), surfaceID: surfaceID,
                onFontSizeChange: { id, size in reported = (id, size) })
        }

        var sizeBefore: Float = 0
        try withRealSurface(makeView: makeView) { view, surface in
            sizeBefore = surface.currentFontSize()
            // A genuine NSEvent built the same way a real keypress arrives, not a
            // synthetic debug-only path.
            _ = view.performKeyEquivalent(with: commandEqual())
            settle(0.3)
        }

        let (reportedID, reportedSize) = try XCTUnwrap(reported)
        XCTAssertEqual(reportedID, surfaceID)
        // Any first report clears a bare `> 0`, so compare against the size before the keypress.
        XCTAssertGreaterThan(reportedSize, sizeBefore)
    }

    /// Cmd+Equal: the "=" key (unshifted "+") is keyCode 24 on a standard US ANSI keyboard.
    private func commandEqual() -> NSEvent {
        keyEvent("=", modifiers: [.command], keyCode: 24)
    }
}
