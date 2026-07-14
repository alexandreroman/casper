import AppKit
import XCTest
@testable import CasperUI

/// End-to-end coverage for the off-screen sized capturer against a real
/// `WKWebView`. `BrowserCapture.snapshot` drives its own borderless off-screen
/// window and awaits the page load internally, so these tests only need to await
/// the returned PNG — no external readiness polling.
@MainActor
final class BrowserCaptureTests: XCTestCase {
    /// A page whose background flips at a 500px width breakpoint, so the two
    /// viewports below actually render differently (the divergence is confirmed
    /// visually in the live smoke test; here we assert geometry only).
    private static let breakpointPage: URL = {
        let html = """
        <html><head><style>
          body { margin: 0; height: 100vh; background: blue; }
          @media (max-width: 500px) { body { background: red; } }
        </style></head><body></body></html>
        """
        let encoded = html.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? html
        return URL(string: "data:text/html," + encoded)!
    }()

    func testCapturesMobileViewport() async throws {
        try await assertCapture(width: 375, height: 800)
    }

    func testCapturesWideViewport() async throws {
        try await assertCapture(width: 1400, height: 900)
    }

    /// Capture at `width`×`height` and assert the PNG is non-empty and its pixel
    /// dimensions are that viewport scaled by a single integer backing factor
    /// (1×, 2×, …). Deriving the factor from the output rather than from
    /// `NSScreen.main` keeps the assertion robust on a headless CI runner.
    private func assertCapture(width: Int, height: Int) async throws {
        let png = try await BrowserCapture.snapshot(url: Self.breakpointPage, width: width, height: height)
        XCTAssertFalse(png.isEmpty, "expected a non-empty PNG")

        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png), "PNG did not decode")
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        XCTAssertEqual(bitmap.pixelsWide % width, 0, "pixel width should be an integer multiple of the viewport width")

        let scale = bitmap.pixelsWide / width
        XCTAssertGreaterThanOrEqual(scale, 1)
        XCTAssertEqual(bitmap.pixelsWide, width * scale)
        XCTAssertEqual(bitmap.pixelsHigh, height * scale, "width and height must share the same backing scale")
    }
}
