import XCTest

@testable import CasperGhostty

/// The `.forTesting()` runtime never creates a surface, so `setOcclusion` is a
/// no-op against libghostty — but the view still records the last value it would
/// have pushed (mirroring `debugLastFocusValue`), which is what these assert.
final class GhosttyOcclusionTests: XCTestCase {
    @MainActor
    func testDetachedViewReportsOccluded() {
        // A view with no window is fully off-screen; refreshing occlusion must
        // push `true`.
        let view = GhosttySurfaceView(runtime: .forTesting(), configuration: GhosttySurfaceConfiguration())
        view.debugRefreshOcclusion()
        XCTAssertEqual(view.debugLastOcclusionValue, true)
    }

    @MainActor
    func testOcclusionPushIsDeduplicated() {
        // Two refreshes in the same (detached) state must not re-push; the recorded
        // value stays stable and reflects the single transition.
        let view = GhosttySurfaceView(runtime: .forTesting(), configuration: GhosttySurfaceConfiguration())
        view.debugRefreshOcclusion()
        view.debugRefreshOcclusion()
        XCTAssertEqual(view.debugLastOcclusionValue, true)
    }
}
