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

    func testExternalURL() {
        // Prefers the committed web view URL over the address text.
        XCTAssertEqual(
            BrowserSurfaceView.externalURL(
                webViewURL: URL(string: "http://localhost:3000/app"), address: "localhost:9999"
            )?.absoluteString,
            "http://localhost:3000/app")
        // Falls back to the normalized address when there is no committed URL yet.
        XCTAssertEqual(
            BrowserSurfaceView.externalURL(webViewURL: nil, address: "localhost:3000")?.absoluteString,
            "http://localhost:3000")
        // No committed URL and no valid address (e.g. still at about:blank, empty address).
        XCTAssertNil(BrowserSurfaceView.externalURL(webViewURL: nil, address: ""))
    }
}
