import CasperCore
import CasperTestSupport
import Foundation
import WebKit
import XCTest
@testable import CasperUI

/// Coverage for every way a *page* can change its own URL. Same-document
/// navigations — `pushState`/`replaceState`, hash changes, same-document history
/// moves — fire no `WKNavigationDelegate` callback at all, so only the KVO
/// observations on `WKWebView.url`/`canGoBack`/`canGoForward` keep
/// `BrowserCoordinator` in sync with a page that routes client-side. Driven
/// through a real off-screen `WKWebView` serving in-memory and on-disk
/// documents, so no server is needed — only the base URL matters.
@MainActor
final class BrowserURLSyncTests: XCTestCase {
    private static let baseAddress = "http://localhost:3000/"
    private static let routedAddress = "http://localhost:3000/routed"
    private static let nextRoutedAddress = "http://localhost:3000/routed-again"

    // MARK: Same-document navigation (no delegate callback fires for any of these)

    func testPushStateUpdatesAddressAndEnablesBack() async throws {
        let coordinator = try await makeLoadedCoordinator()

        _ = try await coordinator.evaluate("history.pushState({}, '', '/routed')")
        // pushState updates the address to the routed URL.
        await waitUntil(timeout: 10) { coordinator.address == Self.routedAddress }
        XCTAssertEqual(coordinator.address, Self.routedAddress)
        // pushState pushes a back-forward entry, so Back must light up as well.
        XCTAssertTrue(coordinator.canGoBack)
    }

    func testReplaceStateUpdatesAddress() async throws {
        let coordinator = try await makeLoadedCoordinator()

        _ = try await coordinator.evaluate("history.replaceState({}, '', '/routed')")
        // replaceState updates the address to the routed URL.
        await waitUntil(timeout: 10) { coordinator.address == Self.routedAddress }
        XCTAssertEqual(coordinator.address, Self.routedAddress)
    }

    func testHashChangesUpdateAddress() async throws {
        let coordinator = try await makeLoadedCoordinator(body: "<a id='jump' href='#anchor'>jump</a>")

        _ = try await coordinator.evaluate("location.hash = '#assigned'")
        // Assigning location.hash appends the fragment to the address.
        await waitUntil(timeout: 10) { coordinator.address == Self.baseAddress + "#assigned" }
        XCTAssertEqual(coordinator.address, Self.baseAddress + "#assigned")

        _ = try await coordinator.evaluate("document.getElementById('jump').click()")
        // Clicking an in-page anchor swaps the fragment in the address.
        await waitUntil(timeout: 10) { coordinator.address == Self.baseAddress + "#anchor" }
        XCTAssertEqual(coordinator.address, Self.baseAddress + "#anchor")
    }

    /// Moves *between two routed entries*, so the traversal stays inside the one
    /// document. Going back onto the entry of a `loadHTMLString` document instead
    /// would leave the web view with a nil URL — WebKit cannot restore a page it
    /// was handed as a string — which is a fixture artefact, not app behaviour.
    func testPageDrivenHistoryBackAndForwardUpdateAddress() async throws {
        let coordinator = try await makeLoadedCoordinator()
        _ = try await coordinator.evaluate("history.pushState({}, '', '/routed')")
        _ = try await coordinator.evaluate("history.pushState({}, '', '/routed-again')")
        // Both pushStates land, leaving the address on the later routed URL.
        await waitUntil(timeout: 10) { coordinator.address == Self.nextRoutedAddress }

        // A script that moves history loses its own reply, so the result is ignored
        // here; the address is what the assertions are about.
        _ = try? await coordinator.evaluate("history.back()")
        // history.back() restores the earlier routed URL.
        await waitUntil(timeout: 10) { coordinator.address == Self.routedAddress }
        XCTAssertEqual(coordinator.address, Self.routedAddress)
        XCTAssertTrue(coordinator.canGoForward)

        _ = try? await coordinator.evaluate("history.forward()")
        // history.forward() re-applies the later routed URL.
        await waitUntil(timeout: 10) { coordinator.address == Self.nextRoutedAddress }
        XCTAssertEqual(coordinator.address, Self.nextRoutedAddress)
    }

    // MARK: Full navigations the page triggers

    /// `location.href` and a link click are ordinary full navigations — they also
    /// commit through the navigation delegate — but they are page-driven, so they
    /// belong in this inventory. Served from disk so no server is needed.
    func testPageDrivenFullNavigationsUpdateAddress() async throws {
        let directory = try makeTwoPageSite()
        let coordinator = BrowserCoordinator(url: .aboutBlank)
        // The placeholder about:blank load commits.
        await waitUntil(timeout: 10) { coordinator.webView.url != nil }
        let firstPage = directory.appendingPathComponent("page1.html")
        coordinator.webView.loadFileURL(firstPage, allowingReadAccessTo: directory)
        // The first page commits.
        await waitUntil(timeout: 10) { coordinator.address.hasSuffix("page1.html") }
        let documentReady = await coordinator.waitFor(
            js: "location.href.endsWith('page1.html')", timeoutMs: 10_000)
        XCTAssertTrue(documentReady, "the document never took on its file URL")

        // A script that navigates away loses its own reply, so the result is ignored.
        _ = try? await coordinator.evaluate("location.href = 'page2.html'")
        // Assigning location.href navigates to the second page.
        await waitUntil(timeout: 10) { coordinator.address.hasSuffix("page2.html") }
        XCTAssertTrue(coordinator.address.hasSuffix("page2.html"), coordinator.address)

        _ = try? await coordinator.evaluate("document.getElementById('back').click()")
        // Clicking the link navigates back to the first page.
        await waitUntil(timeout: 10) { coordinator.address.hasSuffix("page1.html") }
        XCTAssertTrue(coordinator.address.hasSuffix("page1.html"), coordinator.address)
    }

    // MARK: Address-bar navigation

    /// What lets the address bar persist nothing itself: `load` changes `webView.url`
    /// inside the call, so the KVO observation reports the URL through `onCommitURL` —
    /// the path that persists it — before `load` returns and before any network I/O,
    /// which is why no server is needed.
    func testLoadReportsTheURLBeforeReturning() async throws {
        let coordinator = BrowserCoordinator(url: .aboutBlank)
        // The placeholder about:blank load commits.
        await waitUntil(timeout: 10) { coordinator.webView.url != nil }
        var reported: [URL] = []
        coordinator.onCommitURL = { reported.append($0) }
        let url = try XCTUnwrap(URL(string: "http://localhost:1/x"))

        coordinator.load(url)

        XCTAssertEqual(reported.last, url)
    }

    // MARK: Helpers

    /// A coordinator showing a real document at `baseAddress`, ready to be scripted.
    private func makeLoadedCoordinator(body: String = "hi") async throws -> BrowserCoordinator {
        let coordinator = BrowserCoordinator(url: .aboutBlank)
        // `init` issues its own about:blank load. Let it commit first, otherwise it
        // commits *after* the document below and leaves the page on about:blank.
        await waitUntil(timeout: 10) { coordinator.webView.url != nil }

        coordinator.webView.loadHTMLString(
            "<html><body>\(body)</body></html>", baseURL: URL(string: Self.baseAddress)!)
        // The test document commits at the base address.
        await waitUntil(timeout: 10) { coordinator.address == Self.baseAddress }

        // The document adopts the base URL a beat after the web view's `url` commits;
        // scripting history before that is blocked as a change from about:blank, so
        // wait on the page's own view of its location.
        let documentReady = await coordinator.waitFor(
            js: "location.href === '\(Self.baseAddress)'", timeoutMs: 10_000)
        XCTAssertTrue(documentReady, "the document never took on its base URL")
        return coordinator
    }

    /// Two cross-linked pages in a fresh temporary directory, removed at teardown.
    private func makeTwoPageSite() throws -> URL {
        let directory = makeTemporaryDirectory(prefix: "BrowserURLSyncTests")
        try "<html><body>one</body></html>"
            .write(to: directory.appendingPathComponent("page1.html"), atomically: true, encoding: .utf8)
        try "<html><body><a id='back' href='page1.html'>back</a></body></html>"
            .write(to: directory.appendingPathComponent("page2.html"), atomically: true, encoding: .utf8)
        return directory
    }
}
