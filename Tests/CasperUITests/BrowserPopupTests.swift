import Foundation
import XCTest
@testable import CasperUI

/// Unit tests for the popup-adoption decision behind
/// `WKUIDelegate.webView(_:createWebViewWith:for:windowFeatures:)`. The delegate
/// method itself needs a live `WKNavigationAction`, which cannot be constructed
/// in a test, so the decision lives in a static helper taking the two inputs it
/// reads.
final class BrowserPopupTests: XCTestCase {
    func testAdoptsWebPopupThatHasNoTargetFrame() {
        XCTAssertTrue(BrowserCoordinator.shouldAdoptPopup(
            url: URL(string: "http://localhost:3000/other"), hasTargetFrame: false))
        XCTAssertTrue(BrowserCoordinator.shouldAdoptPopup(
            url: URL(string: "https://example.com/"), hasTargetFrame: false))
        XCTAssertTrue(BrowserCoordinator.shouldAdoptPopup(
            url: URL(string: "HTTPS://example.com/"), hasTargetFrame: false))
    }

    func testIgnoresNavigationThatAlreadyHasATargetFrame() {
        XCTAssertFalse(BrowserCoordinator.shouldAdoptPopup(
            url: URL(string: "https://example.com/"), hasTargetFrame: true))
    }

    func testIgnoresSchemesTheAddressBarWouldAlsoReject() {
        for raw in ["file:///etc/passwd", "mailto:someone@example.com", "tel:+123", "casper://open"] {
            XCTAssertFalse(
                BrowserCoordinator.shouldAdoptPopup(url: URL(string: raw), hasTargetFrame: false),
                "\(raw) must not be adopted")
        }
    }

    func testIgnoresRequestWithoutURL() {
        XCTAssertFalse(BrowserCoordinator.shouldAdoptPopup(url: nil, hasTargetFrame: false))
    }
}
