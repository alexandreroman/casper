import Foundation
import XCTest
@testable import CasperAgents

final class ClaudeCodeAdapterTests: XCTestCase {
    private func hooksObject() throws -> [String: Any] {
        let data = try ClaudeCodeAdapter.settingsJSON()
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["hooks"] as? [String: Any])
    }

    func testSettingsWireAllFourEvents() throws {
        let hooks = try hooksObject()
        XCTAssertNotNil(hooks["SessionStart"])
        XCTAssertNotNil(hooks["Stop"])
        XCTAssertNotNil(hooks["Notification"])
        XCTAssertNotNil(hooks["PostToolUse"])
    }

    func testPostToolUseMatchesTodoWrite() throws {
        let hooks = try hooksObject()
        let postToolUse = try XCTUnwrap(hooks["PostToolUse"] as? [[String: Any]])
        XCTAssertEqual(postToolUse.first?["matcher"] as? String, "TodoWrite")
    }

    func testHookCommandIsEmbedded() throws {
        let hooks = try hooksObject()
        let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        let inner = try XCTUnwrap(stop.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(inner.first?["type"] as? String, "command")
        XCTAssertEqual(inner.first?["command"] as? String, "casper hook")
    }

    func testSurfaceEnvironmentCoreVariables() {
        let id = UUID()
        let env = ClaudeCodeAdapter.surfaceEnvironment(
            socketPath: "/tmp/casper.sock", workspaceId: id, portBase: 40010)
        XCTAssertEqual(env["CASPER_SOCKET"], "/tmp/casper.sock")
        XCTAssertEqual(env["CASPER_WORKSPACE_ID"], id.uuidString)
        XCTAssertEqual(env["CASPER_PORT"], "40010")
    }

    func testSurfaceEnvironmentExposesTheWholeBlock() {
        let env = ClaudeCodeAdapter.surfaceEnvironment(
            socketPath: "/tmp/casper.sock", workspaceId: UUID(), portBase: 40010)
        XCTAssertEqual(env["CASPER_PORT_0"], "40010")
        XCTAssertEqual(env["CASPER_PORT_9"], "40019")
        XCTAssertNil(env["CASPER_PORT_10"])
    }
}
