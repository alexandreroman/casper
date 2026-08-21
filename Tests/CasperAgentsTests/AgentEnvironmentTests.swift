import Foundation
import XCTest
@testable import CasperAgents

final class AgentEnvironmentTests: XCTestCase {
    func testSurfaceEnvironmentCoreVariables() {
        let id = UUID()
        let env = AgentEnvironment.surfaceEnvironment(workspaceId: id, portBase: 40010)
        XCTAssertEqual(env["CASPER_WORKSPACE_ID"], id.uuidString)
        XCTAssertEqual(env["CASPER_PORT"], "40010")
    }

    func testSurfaceEnvironmentOmitsPortWhenNoPortBase() {
        let id = UUID()
        let env = AgentEnvironment.surfaceEnvironment(workspaceId: id, portBase: nil)
        XCTAssertNil(env["CASPER_PORT"])
        XCTAssertEqual(env["CASPER_WORKSPACE_ID"], id.uuidString)
    }

    func testSurfaceEnvironmentDoesNotExposeNumberedPorts() {
        let env = AgentEnvironment.surfaceEnvironment(workspaceId: UUID(), portBase: 40010)
        XCTAssertNil(env["CASPER_PORT_0"])
        XCTAssertNil(env["CASPER_PORT_9"])
    }

    func testSurfaceEnvironmentPrependsCasperDirectoryToPath() {
        let env = AgentEnvironment.surfaceEnvironment(
            workspaceId: UUID(), portBase: 40000,
            casperDirectory: "/Apps/Casper.app/Contents/MacOS", basePath: "/usr/bin:/bin")
        XCTAssertEqual(env["PATH"], "/Apps/Casper.app/Contents/MacOS:/usr/bin:/bin")
    }

    func testSurfaceEnvironmentPathIsJustDirectoryWhenNoBasePath() {
        let env = AgentEnvironment.surfaceEnvironment(
            workspaceId: UUID(), portBase: 40000,
            casperDirectory: "/Apps/Casper.app/Contents/MacOS")
        XCTAssertEqual(env["PATH"], "/Apps/Casper.app/Contents/MacOS")
    }

    func testSurfaceEnvironmentOmitsPathWhenNoCasperDirectory() {
        let env = AgentEnvironment.surfaceEnvironment(workspaceId: UUID(), portBase: 40000)
        XCTAssertNil(env["PATH"])
    }

    func testSurfaceEnvironmentInjectsSessionWhenNamed() {
        let env = AgentEnvironment.surfaceEnvironment(
            workspaceId: UUID(), portBase: 40000, sessionName: "dev")
        XCTAssertEqual(env["CASPER_SESSION"], "dev")
    }

    func testSurfaceEnvironmentOmitsSessionForDefault() {
        let env = AgentEnvironment.surfaceEnvironment(workspaceId: UUID(), portBase: 40000)
        XCTAssertNil(env["CASPER_SESSION"])
    }
}
