import CasperCore
import XCTest
@testable import CasperUI

/// Pins the failure the CLI sees when a `browser` verb names a workspace that no
/// longer exists. Every verb routes through the same generic resolve-or-fail
/// helper, so the payload-carrying verbs and the payload-free ones (`wait`,
/// `reload`) must all report the exact same message.
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

    /// The error message of a failed op, or nil when it unexpectedly succeeded.
    private static func failureMessage<T>(_ result: Result<T, BrowserOpError>) -> String? {
        guard case .failure(let error) = result else { return nil }
        return error.message
    }
}
