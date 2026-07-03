import XCTest
@testable import CasperUI

final class BrowserSurfaceViewTests: XCTestCase {
    func testNormalize() {
        XCTAssertEqual(
            BrowserSurfaceView.normalize("localhost:3000")?.absoluteString,
            "http://localhost:3000")
        XCTAssertEqual(
            BrowserSurfaceView.normalize("https://x.dev")?.absoluteString,
            "https://x.dev")
        XCTAssertNil(BrowserSurfaceView.normalize("   "))
    }
}
