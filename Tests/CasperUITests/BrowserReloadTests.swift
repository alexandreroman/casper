import XCTest
import CasperCore
import CasperTestSupport
import Foundation
@testable import CasperUI

/// Unit tests for `BrowserCoordinator`'s reload. The failed-navigation path is
/// driven through the real navigation-delegate methods and the `#if DEBUG`
/// `debugReloadTarget` seam so no live page/server is needed: a failed
/// provisional load must re-issue its URL on reload (`WKWebView.reload()` would
/// no-op), a cancelled navigation is not a failure, and a new navigation clears
/// the failed state. `reload --wait` runs against a real web view loading
/// `data:` and missing `file:` URLs, so no server is needed there either.
@MainActor
final class BrowserReloadTests: XCTestCase {
    private func makeCoordinator() -> BrowserCoordinator {
        BrowserCoordinator(url: URL(string: "http://localhost:3000")!)
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

    // MARK: reload --wait (a real web view)

    /// `reload --wait` must be answered by the reloaded document. The old one stays
    /// committed, and already `complete`, until the new one replaces it, so a wait
    /// it can answer returns before the reload has even started.
    func testReloadWaitReturnsOnlyAfterTheNewDocumentLoads() async throws {
        let page = URL(string: "data:text/html,<p>reload%20me</p>")!
        let coordinator = BrowserCoordinator(url: page)
        let loaded = await coordinator.waitFor(
            js: "location.protocol === 'data:' && document.readyState === 'complete'", timeoutMs: 10_000)
        XCTAssertTrue(loaded, "the test page never loaded")
        _ = try await coordinator.evaluate("window.__marker = 1")

        let result = await makeController(serving: coordinator, page: page)
            .controlBrowserReload(waitReady: true, timeoutMs: 5_000, in: UUID())

        XCTAssertNoThrow(try result.get())
        let marker = try await coordinator.evaluate("typeof window.__marker")
        XCTAssertEqual(marker, "\"undefined\"", "the wait returned while the old document was still loaded")
    }

    /// A reload that fails still settles the wait: the CLI reports the reload as
    /// done, and the failure shows in the browser's error banner.
    func testReloadWaitSettlesWhenTheReloadFails() async {
        // Every load of a file that does not exist fails at once, with no network.
        let unloadable = makeTemporaryDirectory(prefix: "BrowserReloadTests").appendingPathComponent("missing.html")
        let coordinator = BrowserCoordinator(url: unloadable)
        await waitUntil(timeout: 10) { coordinator.loadError != nil }
        XCTAssertEqual(coordinator.debugReloadTarget, unloadable, "a reload must re-issue the failed load")

        let result = await makeController(serving: coordinator, page: unloadable)
            .controlBrowserReload(waitReady: true, timeoutMs: 5_000, in: UUID())

        XCTAssertNoThrow(try result.get())
        XCTAssertNotNil(coordinator.loadError)
    }

    /// A controller whose every workspace lookup resolves to one workspace showing
    /// `page`, served by `coordinator`.
    private func makeController(serving coordinator: BrowserCoordinator, page: URL) -> BrowserAutomationController {
        let workspace = Workspace(
            name: "ws", worktreePath: "/tmp/ws", branch: "main", portBase: 0,
            layout: .leaf(Surface.terminal(cwd: "/tmp/ws")),
            inspector: InspectorState(browser: Surface(kind: .browser(url: page))))
        return BrowserAutomationController(
            resolveWorkspace: { _ in workspace }, coordinator: { _ in coordinator })
    }
}
