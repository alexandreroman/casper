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
        XCTAssertEqual(inner.first?["command"] as? String, "casper hooks feed")
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

    func testSurfaceEnvironmentPrependsCasperDirectoryToPath() {
        let env = ClaudeCodeAdapter.surfaceEnvironment(
            socketPath: "/tmp/casper.sock", workspaceId: UUID(), portBase: 40000,
            casperDirectory: "/Apps/Casper.app/Contents/MacOS", basePath: "/usr/bin:/bin")
        XCTAssertEqual(env["PATH"], "/Apps/Casper.app/Contents/MacOS:/usr/bin:/bin")
    }

    func testSurfaceEnvironmentPathIsJustDirectoryWhenNoBasePath() {
        let env = ClaudeCodeAdapter.surfaceEnvironment(
            socketPath: "/tmp/casper.sock", workspaceId: UUID(), portBase: 40000,
            casperDirectory: "/Apps/Casper.app/Contents/MacOS")
        XCTAssertEqual(env["PATH"], "/Apps/Casper.app/Contents/MacOS")
    }

    func testSurfaceEnvironmentOmitsPathWhenNoCasperDirectory() {
        let env = ClaudeCodeAdapter.surfaceEnvironment(
            socketPath: "/tmp/casper.sock", workspaceId: UUID(), portBase: 40000)
        XCTAssertNil(env["PATH"])
    }

    func testUserSettingsURLPointsAtGlobalClaudeSettings() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("casper-home-\(UUID().uuidString)")
        let url = ClaudeCodeAdapter.userSettingsURL(home: home)
        XCTAssertTrue(url.path.hasSuffix(".claude/settings.json"))
    }

    func testInstallWritesSettingsJSON() throws {
        let settingsURL = try makeSettingsURL()
        defer { cleanUp(settingsURL) }

        try ClaudeCodeAdapter.install(intoUserSettingsAt: settingsURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: settingsURL.path))
        XCTAssertNotNil(try readSettings(at: settingsURL)["hooks"])
    }

    // MARK: - Merge behavior

    private let casperCommand = "casper hooks feed"
    private let casperEvents = ["SessionStart", "Stop", "Notification", "PostToolUse"]

    /// A unique temp `~/.claude/settings.json` per test. Tests MUST always pass
    /// this explicit path to `install` so the developer's real user settings are
    /// never touched. Clean up with `cleanUp`.
    private func makeSettingsURL() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("casper-install-\(UUID().uuidString)")
        let url = root.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    private func cleanUp(_ settingsURL: URL) {
        // Remove the temp root: …/<uuid>/.claude/settings.json → …/<uuid>.
        let root = settingsURL.deletingLastPathComponent().deletingLastPathComponent()
        try? FileManager.default.removeItem(at: root)
    }

    private func seedSettings(_ contents: Data, at settingsURL: URL) throws {
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: settingsURL)
    }

    private func readSettings(at settingsURL: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: settingsURL)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Every command string embedded in an event's entries, flattened.
    private func commands(inEvent event: [[String: Any]]) -> [String] {
        event.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }
    }

    private func casperEntryCount(inEvent event: [[String: Any]]) -> Int {
        event.filter { entry in
            (entry["hooks"] as? [[String: Any]])?
                .contains { ($0["command"] as? String) == casperCommand } ?? false
        }.count
    }

    func testInstallPreservesForeignTopLevelKeys() throws {
        let settingsURL = try makeSettingsURL()
        defer { cleanUp(settingsURL) }

        let seed: [String: Any] = [
            "permissions": ["allow": ["Bash"]],
            "hooks": [
                "PreToolUse": [["hooks": [["type": "command", "command": "user-hook"]]]],
            ],
        ]
        try seedSettings(
            try JSONSerialization.data(withJSONObject: seed), at: settingsURL)

        try ClaudeCodeAdapter.install(intoUserSettingsAt: settingsURL)

        let root = try readSettings(at: settingsURL)
        let permissions = try XCTUnwrap(root["permissions"] as? [String: Any])
        XCTAssertEqual(permissions["allow"] as? [String], ["Bash"])

        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["PreToolUse"])
        for event in casperEvents {
            let entries = try XCTUnwrap(hooks[event] as? [[String: Any]])
            XCTAssertTrue(
                commands(inEvent: entries).contains(casperCommand),
                "event \(event) should carry the Casper hook command")
        }
    }

    func testInstallIsIdempotent() throws {
        let settingsURL = try makeSettingsURL()
        defer { cleanUp(settingsURL) }

        try ClaudeCodeAdapter.install(intoUserSettingsAt: settingsURL)
        try ClaudeCodeAdapter.install(intoUserSettingsAt: settingsURL)

        let hooks = try XCTUnwrap(readSettings(at: settingsURL)["hooks"] as? [String: Any])
        for event in casperEvents {
            let entries = try XCTUnwrap(hooks[event] as? [[String: Any]])
            XCTAssertEqual(
                casperEntryCount(inEvent: entries), 1,
                "event \(event) should have exactly one Casper entry")
        }
    }

    func testInstallPreservesUserEntryOnCasperOwnedEvent() throws {
        let settingsURL = try makeSettingsURL()
        defer { cleanUp(settingsURL) }

        let seed: [String: Any] = [
            "hooks": [
                "SessionStart": [["hooks": [["type": "command", "command": "user-session"]]]],
            ],
        ]
        try seedSettings(
            try JSONSerialization.data(withJSONObject: seed), at: settingsURL)

        try ClaudeCodeAdapter.install(intoUserSettingsAt: settingsURL)

        let hooks = try XCTUnwrap(readSettings(at: settingsURL)["hooks"] as? [String: Any])
        let sessionStart = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        let commands = commands(inEvent: sessionStart)
        XCTAssertTrue(commands.contains("user-session"))
        XCTAssertTrue(commands.contains(casperCommand))
    }

    func testInstallThrowsOnMalformedExistingJSONAndLeavesFileUnchanged() throws {
        let settingsURL = try makeSettingsURL()
        defer { cleanUp(settingsURL) }

        let malformed = Data("not json{".utf8)
        try seedSettings(malformed, at: settingsURL)

        XCTAssertThrowsError(try ClaudeCodeAdapter.install(intoUserSettingsAt: settingsURL))

        let after = try Data(contentsOf: settingsURL)
        XCTAssertEqual(after, malformed, "malformed file must be left byte-for-byte intact")
    }
}
