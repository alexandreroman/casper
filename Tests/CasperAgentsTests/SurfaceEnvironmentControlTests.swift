import XCTest
import CasperCore
@testable import CasperAgents

final class SurfaceEnvironmentControlTests: XCTestCase {
    func testInjectsControlSocketWhenProvided() {
        let env = ClaudeCodeAdapter.surfaceEnvironment(
            socketPath: "/hooks.sock", workspaceId: UUID(), portBase: 40000,
            controlSocketPath: "/control.sock")
        XCTAssertEqual(env["CASPER_CONTROL_SOCKET"], "/control.sock")
    }

    func testOmitsControlSocketWhenNil() {
        let env = ClaudeCodeAdapter.surfaceEnvironment(
            socketPath: "/hooks.sock", workspaceId: UUID(), portBase: 40000)
        XCTAssertNil(env["CASPER_CONTROL_SOCKET"])
    }

    func testControlSocketAndWorkspaceIdPresentWhenHookSocketNil() {
        let workspaceId = UUID()
        let env = ClaudeCodeAdapter.surfaceEnvironment(
            socketPath: nil, workspaceId: workspaceId, portBase: 40000,
            controlSocketPath: "/control.sock")
        XCTAssertNil(env["CASPER_SOCKET"])
        XCTAssertEqual(env["CASPER_CONTROL_SOCKET"], "/control.sock")
        XCTAssertEqual(env["CASPER_WORKSPACE_ID"], workspaceId.uuidString)
        XCTAssertEqual(env["CASPER_PORT"], "40000")
    }
}
