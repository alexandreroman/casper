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
        // Two refreshes in the same (detached) state must reach libghostty once. The
        // recorded value cannot show that — it reads `true` either way — so the push
        // count is what pins the dedup guard.
        let view = GhosttySurfaceView(runtime: .forTesting(), configuration: GhosttySurfaceConfiguration())
        view.debugRefreshOcclusion()
        view.debugRefreshOcclusion()
        XCTAssertEqual(view.debugLastOcclusionValue, true)
        XCTAssertEqual(view.debugOcclusionPushCount, 1)
    }
}
