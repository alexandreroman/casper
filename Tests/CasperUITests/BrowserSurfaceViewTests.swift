import XCTest
@testable import CasperUI

@MainActor
final class BrowserSurfaceViewTests: XCTestCase {
    func testNormalize() {
        XCTAssertEqual(
            BrowserSurfaceView.normalize("localhost:3000")?.absoluteString,
            "http://localhost:3000")
        XCTAssertEqual(
            BrowserSurfaceView.normalize("https://x.dev")?.absoluteString,
            "https://x.dev")
        // A scheme + host + port must be honored, never double-prefixed.
        XCTAssertEqual(
            BrowserSurfaceView.normalize("http://localhost:9000")?.absoluteString,
            "http://localhost:9000")
        XCTAssertNil(BrowserSurfaceView.normalize("   "))
    }
}
