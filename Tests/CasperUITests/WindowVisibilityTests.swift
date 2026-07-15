import CasperCore
import XCTest
@testable import CasperUI

final class WindowVisibilityTests: XCTestCase {
    @MainActor
    func testAppModelDefaultsToVisible() {
        // A headless AppModel (no window attached) must behave as visible so
        // tests and any pre-window state do not suspend work spuriously.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("casper-test-\(UUID().uuidString).json")
        let model = AppModel(sessionStore: SessionStore(fileURL: url))
        XCTAssertTrue(model.isWindowVisible)
    }
}
