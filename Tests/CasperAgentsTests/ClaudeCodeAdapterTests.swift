import Foundation
import XCTest
@testable import CasperAgents

final class ClaudeCodeAdapterTests: XCTestCase {
    func testSurfaceEnvironmentCoreVariables() {
        let id = UUID()
        let env = ClaudeCodeAdapter.surfaceEnvironment(workspaceId: id, portBase: 40010)
        XCTAssertEqual(env["CASPER_WORKSPACE_ID"], id.uuidString)
        XCTAssertEqual(env["CASPER_PORT"], "40010")
    }

    func testSurfaceEnvironmentExposesTheWholeBlock() {
        let env = ClaudeCodeAdapter.surfaceEnvironment(workspaceId: UUID(), portBase: 40010)
        XCTAssertEqual(env["CASPER_PORT_0"], "40010")
        XCTAssertEqual(env["CASPER_PORT_9"], "40019")
        XCTAssertNil(env["CASPER_PORT_10"])
    }

    func testSurfaceEnvironmentPrependsCasperDirectoryToPath() {
        let env = ClaudeCodeAdapter.surfaceEnvironment(
            workspaceId: UUID(), portBase: 40000,
            casperDirectory: "/Apps/Casper.app/Contents/MacOS", basePath: "/usr/bin:/bin")
        XCTAssertEqual(env["PATH"], "/Apps/Casper.app/Contents/MacOS:/usr/bin:/bin")
    }

    func testSurfaceEnvironmentPathIsJustDirectoryWhenNoBasePath() {
        let env = ClaudeCodeAdapter.surfaceEnvironment(
            workspaceId: UUID(), portBase: 40000,
            casperDirectory: "/Apps/Casper.app/Contents/MacOS")
        XCTAssertEqual(env["PATH"], "/Apps/Casper.app/Contents/MacOS")
    }

    func testSurfaceEnvironmentOmitsPathWhenNoCasperDirectory() {
        let env = ClaudeCodeAdapter.surfaceEnvironment(workspaceId: UUID(), portBase: 40000)
        XCTAssertNil(env["PATH"])
    }
}
