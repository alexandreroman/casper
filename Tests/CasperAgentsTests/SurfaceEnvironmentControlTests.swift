import XCTest
import CasperCore
@testable import CasperAgents

final class SurfaceEnvironmentControlTests: XCTestCase {
    func testInjectsControlSocketWhenProvided() {
        let env = ClaudeCodeAdapter.surfaceEnvironment(
            workspaceId: UUID(), portBase: 40000,
            controlSocketPath: "/control.sock")
        XCTAssertEqual(env["CASPER_CONTROL_SOCKET"], "/control.sock")
    }

    func testOmitsControlSocketWhenNil() {
        let env = ClaudeCodeAdapter.surfaceEnvironment(
            workspaceId: UUID(), portBase: 40000)
        XCTAssertNil(env["CASPER_CONTROL_SOCKET"])
    }

    func testControlSocketAndWorkspaceIdPresent() {
        let workspaceId = UUID()
        let env = ClaudeCodeAdapter.surfaceEnvironment(
            workspaceId: workspaceId, portBase: 40000,
            controlSocketPath: "/control.sock")
        XCTAssertEqual(env["CASPER_CONTROL_SOCKET"], "/control.sock")
        XCTAssertEqual(env["CASPER_WORKSPACE_ID"], workspaceId.uuidString)
        XCTAssertEqual(env["CASPER_PORT"], "40000")
    }
}
