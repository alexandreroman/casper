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

    func testInstallWritesSettingsLocalJSON() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("casper-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try ClaudeCodeAdapter.install(intoWorktreeAt: dir.path)

        let path = ClaudeCodeAdapter.settingsPath(inWorktreeAt: dir.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(path.hasSuffix(".claude/settings.local.json"))

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(root["hooks"])
    }

    // MARK: - Merge behavior

    private let casperCommand = "casper hooks feed"
    private let casperEvents = ["SessionStart", "Stop", "Notification", "PostToolUse"]

    private func makeWorktree() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("casper-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func seedSettings(_ contents: Data, atWorktree dir: URL) throws {
        let claudeDir = dir.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(
            at: claudeDir, withIntermediateDirectories: true)
        try contents.write(to: claudeDir.appendingPathComponent("settings.local.json"))
    }

    private func readSettings(atWorktree path: String) throws -> [String: Any] {
        let settingsPath = ClaudeCodeAdapter.settingsPath(inWorktreeAt: path)
        let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
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
        let dir = try makeWorktree()
        defer { try? FileManager.default.removeItem(at: dir) }

        let seed: [String: Any] = [
            "permissions": ["allow": ["Bash"]],
            "hooks": [
                "PreToolUse": [["hooks": [["type": "command", "command": "user-hook"]]]],
            ],
        ]
        try seedSettings(
            try JSONSerialization.data(withJSONObject: seed), atWorktree: dir)

        try ClaudeCodeAdapter.install(intoWorktreeAt: dir.path)

        let root = try readSettings(atWorktree: dir.path)
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
        let dir = try makeWorktree()
        defer { try? FileManager.default.removeItem(at: dir) }

        try ClaudeCodeAdapter.install(intoWorktreeAt: dir.path)
        try ClaudeCodeAdapter.install(intoWorktreeAt: dir.path)

        let hooks = try XCTUnwrap(readSettings(atWorktree: dir.path)["hooks"] as? [String: Any])
        for event in casperEvents {
            let entries = try XCTUnwrap(hooks[event] as? [[String: Any]])
            XCTAssertEqual(
                casperEntryCount(inEvent: entries), 1,
                "event \(event) should have exactly one Casper entry")
        }
    }

    func testInstallPreservesUserEntryOnCasperOwnedEvent() throws {
        let dir = try makeWorktree()
        defer { try? FileManager.default.removeItem(at: dir) }

        let seed: [String: Any] = [
            "hooks": [
                "SessionStart": [["hooks": [["type": "command", "command": "user-session"]]]],
            ],
        ]
        try seedSettings(
            try JSONSerialization.data(withJSONObject: seed), atWorktree: dir)

        try ClaudeCodeAdapter.install(intoWorktreeAt: dir.path)

        let hooks = try XCTUnwrap(readSettings(atWorktree: dir.path)["hooks"] as? [String: Any])
        let sessionStart = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        let commands = commands(inEvent: sessionStart)
        XCTAssertTrue(commands.contains("user-session"))
        XCTAssertTrue(commands.contains(casperCommand))
    }

    func testInstallThrowsOnMalformedExistingJSONAndLeavesFileUnchanged() throws {
        let dir = try makeWorktree()
        defer { try? FileManager.default.removeItem(at: dir) }

        let malformed = Data("not json{".utf8)
        try seedSettings(malformed, atWorktree: dir)
        let settingsPath = ClaudeCodeAdapter.settingsPath(inWorktreeAt: dir.path)

        XCTAssertThrowsError(try ClaudeCodeAdapter.install(intoWorktreeAt: dir.path))

        let after = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        XCTAssertEqual(after, malformed, "malformed file must be left byte-for-byte intact")
    }
}
