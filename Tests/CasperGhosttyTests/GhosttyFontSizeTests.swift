import AppKit
import GhosttyKit
import XCTest

@testable import CasperGhostty

/// Spike (see [[ghostty-inherited-config-font-size]]): confirms
/// `ghostty_surface_inherited_config` reflects a LIVE, runtime-adjusted font
/// size — its documented purpose is building a config for a *new child* split,
/// and whether it also echoes the current surface's own live size was
/// unconfirmed before this test. Runs on the shared `withRealSurface` harness —
/// the `.forTesting()` runtime never creates a surface.
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
    func testFontSizeChangeClosureDoesNotFireWithoutALiveSurface() throws {
        var firedCount = 0
        let view = GhosttySurfaceView(
            runtime: .forTesting(), configuration: GhosttySurfaceConfiguration(),
            onFontSizeChange: { _, _ in firedCount += 1 })

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: 0, context: nil, characters: "=",
            charactersIgnoringModifiers: "=", isARepeat: false, keyCode: 24))
        XCTAssertFalse(view.performKeyEquivalent(with: event))

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

        try withRealSurface(makeView: makeView) { view, _ in
            // Cmd+Equal: the "=" key (unshifted "+") is keyCode 24 on a standard US
            // ANSI keyboard. This is a genuine NSEvent built the same way a real
            // keypress arrives, not a synthetic debug-only path.
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                windowNumber: 0, context: nil, characters: "=",
                charactersIgnoringModifiers: "=", isARepeat: false, keyCode: 24)!
            _ = view.performKeyEquivalent(with: event)
            settle(0.3)
        }

        let (reportedID, reportedSize) = try XCTUnwrap(reported)
        XCTAssertEqual(reportedID, surfaceID)
        XCTAssertGreaterThan(reportedSize, 0)
    }
}
