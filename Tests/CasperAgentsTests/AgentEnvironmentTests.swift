import Foundation
import XCTest
@testable import CasperAgents

final class AgentEnvironmentTests: XCTestCase {
    func testSurfaceEnvironmentCoreVariables() {
        let id = UUID()
        let env = AgentEnvironment.surfaceEnvironment(workspaceId: id, portBase: 40010)
        XCTAssertEqual(env["CASPER_WORKSPACE_ID"], id.casperID)
        XCTAssertEqual(env["CASPER_PORT"], "40010")
    }

    func testSurfaceEnvironmentOmitsPortWhenNoPortBase() {
        let id = UUID()
        let env = AgentEnvironment.surfaceEnvironment(workspaceId: id, portBase: nil)
        XCTAssertNil(env["CASPER_PORT"])
        XCTAssertEqual(env["CASPER_WORKSPACE_ID"], id.casperID)
    }

    /// Pins the canonical lowercase form against a fixed, letter-bearing id.
    /// `UUID()` alone would be a weak guard here: a randomly minted id can consist
    /// of digits only, and no case check can catch a bypass on such an id.
    func testSurfaceEnvironmentLowercasesTheWorkspaceID() throws {
        let id = try XCTUnwrap(UUID(uuidString: "ABCDEF01-ABCD-4BCD-8BCD-ABCDEF012345"))
        let env = AgentEnvironment.surfaceEnvironment(workspaceId: id, portBase: nil)
        XCTAssertEqual(env["CASPER_WORKSPACE_ID"], "abcdef01-abcd-4bcd-8bcd-abcdef012345")
    }

    func testSurfaceEnvironmentMinimalKeySet() {
        let env = AgentEnvironment.surfaceEnvironment(workspaceId: UUID(), portBase: 40010)
        XCTAssertEqual(Set(env.keys), ["CASPER_WORKSPACE_ID", "CASPER_PORT"])
    }

    func testSurfaceEnvironmentFullKeySet() {
        let env = AgentEnvironment.surfaceEnvironment(
            workspaceId: UUID(), portBase: 40010,
            casperDirectory: "/Apps/Casper.app/Contents/MacOS", basePath: "/usr/bin",
            controlSocketPath: "/control.sock", sessionName: "dev")
        XCTAssertEqual(
            Set(env.keys),
            ["CASPER_WORKSPACE_ID", "CASPER_PORT", "CASPER_CONTROL_SOCKET", "CASPER_SESSION", "PATH"])
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

    func testSurfaceEnvironmentInjectsSessionWhenNamed() {
        let env = AgentEnvironment.surfaceEnvironment(
            workspaceId: UUID(), portBase: 40000, sessionName: "dev")
        XCTAssertEqual(env["CASPER_SESSION"], "dev")
    }

    func testSurfaceEnvironmentInjectsControlSocketWhenProvided() {
        let env = AgentEnvironment.surfaceEnvironment(
            workspaceId: UUID(), portBase: 40000,
            controlSocketPath: "/control.sock")
        XCTAssertEqual(env["CASPER_CONTROL_SOCKET"], "/control.sock")
    }
}
