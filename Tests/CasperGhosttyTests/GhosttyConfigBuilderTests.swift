import Foundation
import GhosttyKit
import XCTest
@testable import CasperGhostty

/// The config build sequence's theme fallback: a user theme that loads replaces
/// Casper's, one that cannot load (a named theme without Ghostty's resources dir)
/// falls back to Casper's built-in light and dark themes.
final class GhosttyConfigBuilderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(ghosttyInitialized, "ghostty_init failed")
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("casper-builder-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fallback

    func testUnresolvableNamedThemeFallsBackToCasperLight() throws {
        let config = try build(user: "theme = NoSuchCasperTestTheme\n")
        defer { ghostty_config_free(config) }
        XCTAssertEqual(background(of: config), [0xff, 0xff, 0xff])
    }

    func testLoadableUserThemeStillReplacesOurs() throws {
        let userTheme = directory.appendingPathComponent("user-theme")
        try "background = #102030\n".write(to: userTheme, atomically: true, encoding: .utf8)
        let config = try build(user: "theme = \(userTheme.path)\n")
        defer { ghostty_config_free(config) }
        XCTAssertEqual(background(of: config), [0x10, 0x20, 0x30])
    }

    func testUserExplicitKeyStillWins() throws {
        let config = try build(user: "background = #123456\n")
        defer { ghostty_config_free(config) }
        XCTAssertEqual(background(of: config), [0x12, 0x34, 0x56])
    }

    func testWithoutUserThemeCasperLightApplies() throws {
        let config = try build(user: nil)
        defer { ghostty_config_free(config) }
        XCTAssertEqual(background(of: config), [0xff, 0xff, 0xff])
    }

    func testExplicitKeyStillWinsAfterTheFallback() throws {
        let config = try build(user: "theme = NoSuchCasperTestTheme\nbackground = #123456\n")
        defer { ghostty_config_free(config) }
        XCTAssertEqual(background(of: config), [0x12, 0x34, 0x56])
    }

    // MARK: - isThemeLoadFailure

    func testThemeLoadFailureMessagesAreRecognised() {
        let messages = [
            #"theme "Arthur" not found, tried path "/x/themes/Arthur""#,
            #"theme "a/b" cannot include path separators unless it is an absolute path"#,
            #"failed to load theme from the path "/x/theme": FileNotFound"#,
            #"failed to load theme from the path "/x/theme""#,
            #"failed to load theme "Arthur" from the file "/x/Arthur": error.Foo"#,
            #"not reading theme from "Arthur": something"#,
        ]
        for message in messages {
            XCTAssertTrue(GhosttyDefaultConfig.isThemeLoadFailure(message), message)
        }
    }

    func testUnrelatedDiagnosticsAreNotThemeLoadFailures() {
        XCTAssertFalse(GhosttyDefaultConfig.isThemeLoadFailure(#"unknown field "foo""#))
        XCTAssertFalse(GhosttyDefaultConfig.isThemeLoadFailure(
            "cli: compatibility handler for bold-is-bright handled error"))
    }

    // MARK: - Helpers

    /// Builds through the production sequence, with `user` standing in for the
    /// user's default and recursive config files.
    private func build(user: String?) throws -> ghostty_config_t {
        let themes = try GhosttyThemeFiles.write(to: directory.appendingPathComponent("themes"))
        let userFile = directory.appendingPathComponent("user.ghostty")
        if let user { try user.write(to: userFile, atomically: true, encoding: .utf8) }
        return try XCTUnwrap(GhosttyConfigBuilder.makeConfig(themes: themes) { config in
            if user != nil { ghostty_config_load_file(config, userFile.path) }
        })
    }

    private func background(of config: ghostty_config_t) -> [UInt8] {
        var color = ghostty_config_color_s()
        let key = "background"
        XCTAssertTrue(ghostty_config_get(config, &color, key, UInt(key.utf8.count)))
        return [color.r, color.g, color.b]
    }
}
