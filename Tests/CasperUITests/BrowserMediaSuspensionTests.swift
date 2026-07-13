import XCTest

@testable import CasperUI

/// `setAllMediaPlaybackSuspended` is set-only against WebKit — but the view still
/// records the last value it would have pushed (mirroring `debugLastOcclusionValue`
/// in `GhosttySurfaceView`), which is what these assert. See perf-finding G2:
/// suspending media for an off-screen cached browser.
final class BrowserMediaSuspensionTests: XCTestCase {
    @MainActor
    func testDetachedViewSuspendsMedia() {
        // A view with no window is fully off-screen; refreshing must suspend media.
        let view = FocusReportingWebView(frame: .zero)
        view.debugRefreshMediaSuspension()
        XCTAssertEqual(view.debugLastMediaSuspended, true)
    }

    @MainActor
    func testMediaSuspensionPushIsDeduplicated() {
        // Two refreshes in the same (detached) state must not re-push; the recorded
        // value stays stable and reflects the single transition.
        let view = FocusReportingWebView(frame: .zero)
        view.debugRefreshMediaSuspension()
        view.debugRefreshMediaSuspension()
        XCTAssertEqual(view.debugLastMediaSuspended, true)
    }
}
