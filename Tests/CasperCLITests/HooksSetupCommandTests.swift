import ArgumentParser
import Foundation
import XCTest
import CasperAgents
import CasperCLI

final class HooksSetupCommandTests: XCTestCase {
    /// A unique temp settings file per test. The command MUST always be driven
    /// with `--settings` so the developer's real ~/.claude/settings.json is
    /// never touched. Returns the file URL; clean up its temp root with `cleanUp`.
    private func makeSettingsURL() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("casper-cli-setup-\(UUID().uuidString)")
        let url = root.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    private func cleanUp(_ settingsURL: URL) {
        let root = settingsURL.deletingLastPathComponent().deletingLastPathComponent()
        try? FileManager.default.removeItem(at: root)
    }

    func testSetupWritesSettingsIntoGivenFile() throws {
        let settingsURL = try makeSettingsURL()
        defer { cleanUp(settingsURL) }

        var command = HooksSetupCommand()
        command.settings = settingsURL.path
        try command.run()

        XCTAssertTrue(FileManager.default.fileExists(atPath: settingsURL.path))
        let data = try Data(contentsOf: settingsURL)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(root["hooks"])
    }

    func testSetupDefaultsToUserSettingsWhenNoOverride() throws {
        let command = try HooksSetupCommand.parse([])
        XCTAssertNil(command.settings)
    }

    func testSetupMapsInstallFailureToExitCodeFailure() throws {
        let settingsURL = try makeSettingsURL()
        defer { cleanUp(settingsURL) }

        // A malformed existing settings file makes `install` throw a
        // ClaudeCodeAdapterError; `run()` must surface it as a clean exit.
        try Data("not json{".utf8).write(to: settingsURL)

        var command = HooksSetupCommand()
        command.settings = settingsURL.path
        XCTAssertThrowsError(try command.run()) { error in
            XCTAssertEqual(error as? ExitCode, .failure)
        }
    }
}
