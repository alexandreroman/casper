import CasperCore
import XCTest
@testable import CasperUI

/// Pins the failures the CLI sees from a `browser` verb it cannot carry out.
///
/// For a workspace that no longer exists: every verb routes through the same
/// generic resolve-or-fail helper, so the payload-carrying verbs and the
/// payload-free ones (`wait`, `reload`) must all report the exact same message.
/// For `screenshot --url`: an override that cannot be honoured must fail rather
/// than capture some other page.
@MainActor
final class BrowserAutomationControllerTests: XCTestCase {
    /// A controller whose workspace lookup never resolves.
    private let controller = BrowserAutomationController(
        resolveWorkspace: { _ in nil }, coordinator: { _ in nil })

    func testEvalReportsUnknownWorkspace() async {
        let result = await controller.controlBrowserEval("1", in: UUID())
        XCTAssertEqual(Self.failureMessage(result), "workspace not found")
    }

    func testWaitReportsUnknownWorkspace() async {
        let result = await controller.controlBrowserWait(
            js: "true", timeoutMs: 10, description: "a selector", in: UUID())
        XCTAssertEqual(Self.failureMessage(result), "workspace not found")
    }

    func testReloadReportsUnknownWorkspace() async {
        let result = await controller.controlBrowserReload(waitReady: true, timeoutMs: 10, in: UUID())
        XCTAssertEqual(Self.failureMessage(result), "workspace not found")
    }

    /// A controller whose workspace resolves and whose browser surface carries a
    /// persisted page, so a `--url` override reaches the resolver with a fallback
    /// available to wrongly resolve to. The coordinator stays nil: the live-URL and
    /// persisted-URL fallbacks are the same fall-through, and a real
    /// `BrowserCoordinator` would have to finish a page load to expose a live URL.
    private let controllerWithPersistedPage = BrowserAutomationController(
        resolveWorkspace: { _ in
            let persisted = URL(string: "data:text/html,<html></html>")!
            return Workspace(
                name: "ws", worktreePath: "/tmp/ws", branch: "main", portBase: 0,
                layout: .leaf(Surface.terminal(cwd: "/tmp/ws")),
                inspector: InspectorState(browser: Surface(kind: .browser(url: persisted))))
        },
        coordinator: { _ in nil })

    /// A `--url` the resolver cannot honour — unparseable, scheme-less, or the blank
    /// page — must fail the capture naming that value. Guards the fix where the
    /// override guard falling through resolved the capture to the page the browser
    /// happened to be on, so `screenshot --url about:blank` reported success and wrote
    /// a PNG of a completely different page.
    func testUnusableScreenshotURLOverrideFailsInsteadOfCapturingAnotherPage() async {
        for override in ["about:blank", "not a url", "/tmp/page.html"] {
            let result = await controllerWithPersistedPage.controlBrowserScreenshot(
                in: UUID(), to: "/dev/null", url: override)
            XCTAssertEqual(
                Self.failureMessage(result),
                "cannot capture '\(override)' (expected an absolute URL like https://example.com)")
        }
    }

    /// The error message of a failed op, or nil when it unexpectedly succeeded.
    private static func failureMessage<T>(_ result: Result<T, BrowserOpError>) -> String? {
        guard case .failure(let error) = result else { return nil }
        return error.message
    }
}
