import ArgumentParser
import Foundation
import XCTest
import CasperAgents
import CasperCLI

final class HooksSetupCommandTests: XCTestCase {
    func testSetupWritesSettingsIntoGivenWorktree() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("casper-cli-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var command = try HooksSetupCommand.parse([dir.path])
        try command.run()

        let settings = ClaudeCodeAdapter.settingsPath(inWorktreeAt: dir.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: settings))
    }

    func testSetupDefaultsToCurrentDirectoryWhenNoArgument() throws {
        let command = try HooksSetupCommand.parse([])
        XCTAssertNil(command.worktree)
    }

    func testSetupMapsInstallFailureToExitCodeFailure() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("casper-cli-setup-fail-\(UUID().uuidString)")
        let claude = dir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(
            at: claude, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A malformed existing settings file makes `install` throw a
        // ClaudeCodeAdapterError; `run()` must surface it as a clean exit.
        try Data("not json{".utf8).write(
            to: claude.appendingPathComponent("settings.local.json"))

        var command = HooksSetupCommand()
        command.worktree = dir.path
        XCTAssertThrowsError(try command.run()) { error in
            XCTAssertEqual(error as? ExitCode, .failure)
        }
    }
}
