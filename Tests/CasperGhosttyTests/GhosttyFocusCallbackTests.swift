import Foundation
import XCTest

@testable import CasperGhostty

final class GhosttyFocusCallbackTests: XCTestCase {
    /// `blurForLayoutChange()` pushes a "not focused" state into libghostty. The
    /// `.forTesting()` runtime creates no surface, but `debugLastFocusValue` is
    /// recorded regardless, so the intent is headlessly observable.
    @MainActor
    func testBlurForLayoutChangeRecordsFocusLost() {
        let view = GhosttySurfaceView(
            runtime: .forTesting(), configuration: GhosttySurfaceConfiguration())
        view.blurForLayoutChange()
        XCTAssertEqual(view.debugLastFocusValue, false)
    }

    /// Becoming first responder records focus gained; resigning records it lost.
    /// Both go through the same `pushFocus` seam, observable without real OS focus.
    @MainActor
    func testFirstResponderTransitionsRecordFocusValue() {
        let view = GhosttySurfaceView(
            runtime: .forTesting(), configuration: GhosttySurfaceConfiguration())
        _ = view.becomeFirstResponder()
        XCTAssertEqual(view.debugLastFocusValue, true)
        _ = view.resignFirstResponder()
        XCTAssertEqual(view.debugLastFocusValue, false)
    }
}
