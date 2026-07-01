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
}
