import XCTest
import CasperCore
@testable import CasperUI

/// Unit tests for `BrowserCoordinator`'s failed-navigation reload path, driven
/// through the real navigation-delegate methods and the `#if DEBUG`
/// `debugReloadTarget` seam so no live page/server is needed: a failed
/// provisional load must re-issue its URL on reload (`WKWebView.reload()` would
/// no-op), a cancelled navigation is not a failure, and a new navigation clears
/// the failed state.
@MainActor
final class BrowserReloadTests: XCTestCase {
    private func makeCoordinator() -> BrowserCoordinator {
        BrowserCoordinator(surfaceID: UUID(), url: URL(string: "http://localhost:3000")!)
    }

    private func failureError(code: Int, url: URL) -> NSError {
        NSError(domain: NSURLErrorDomain, code: code, userInfo: [
            NSURLErrorFailingURLErrorKey: url,
            NSLocalizedDescriptionKey: "Could not connect to the server."
        ])
    }

    func testReloadAfterProvisionalFailureReissuesFailedURL() {
        let coordinator = makeCoordinator()
        let failedURL = URL(string: "http://localhost:3000")!
        let error = failureError(code: NSURLErrorCannotConnectToHost, url: failedURL)
        coordinator.webView(coordinator.webView, didFailProvisionalNavigation: nil, withError: error)
        XCTAssertEqual(coordinator.debugReloadTarget, failedURL)
        XCTAssertNotNil(coordinator.loadError)
    }

    func testFailingURLFallsBackToStringKey() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost, userInfo: [
            NSURLErrorFailingURLStringErrorKey: "http://localhost:3000"
        ])
        XCTAssertEqual(BrowserCoordinator.failingURL(from: error), URL(string: "http://localhost:3000"))
    }

    func testCancelledNavigationIsNotTreatedAsFailure() {
        let coordinator = makeCoordinator()
        let error = failureError(code: NSURLErrorCancelled, url: URL(string: "http://localhost:3000")!)
        coordinator.webView(coordinator.webView, didFailProvisionalNavigation: nil, withError: error)
        XCTAssertNil(coordinator.debugReloadTarget)
        XCTAssertNil(coordinator.loadError)
    }

    func testStartingNewNavigationClearsFailedState() {
        let coordinator = makeCoordinator()
        let error = failureError(code: NSURLErrorCannotConnectToHost, url: URL(string: "http://localhost:3000")!)
        coordinator.webView(coordinator.webView, didFailProvisionalNavigation: nil, withError: error)
        XCTAssertNotNil(coordinator.debugReloadTarget)

        coordinator.webView(coordinator.webView, didStartProvisionalNavigation: nil)
        XCTAssertNil(coordinator.debugReloadTarget)
        XCTAssertNil(coordinator.loadError)
    }
}
