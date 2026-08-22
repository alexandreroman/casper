import Foundation
import XCTest
@testable import CasperAgents

final class SurfaceEnvironmentControlTests: XCTestCase {
    func testInjectsControlSocketWhenProvided() {
        let env = AgentEnvironment.surfaceEnvironment(
            workspaceId: UUID(), portBase: 40000,
            controlSocketPath: "/control.sock")
        XCTAssertEqual(env["CASPER_CONTROL_SOCKET"], "/control.sock")
    }

    func testOmitsControlSocketWhenNil() {
        let env = AgentEnvironment.surfaceEnvironment(
            workspaceId: UUID(), portBase: 40000)
        XCTAssertNil(env["CASPER_CONTROL_SOCKET"])
    }
}
