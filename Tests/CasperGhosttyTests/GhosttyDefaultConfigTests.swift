import Foundation
import GhosttyKit
import XCTest
@testable import CasperGhostty

/// Casper's built-in colours reach libghostty as two theme files behind one
/// conditional `theme` line, never as explicit keys: in Ghostty an explicit
/// colour key beats any theme, so explicit defaults would mask a user's own
/// `theme = …`.
final class GhosttyDefaultConfigTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(ghosttyInitialized, "ghostty_init failed")
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("casper-theme-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testDefaultsCarryOnlyTheThemeLineAndClipboardPolicy() throws {
        let paths = try GhosttyThemeFiles.write(to: directory)
        let text = GhosttyDefaultConfig.text(themes: paths)
        let keys = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        XCTAssertEqual(keys, [
            "theme = light:\(paths.light.path),dark:\(paths.dark.path)",
            "clipboard-write = ask",
        ])
    }

    func testWithoutThemeFilesTheDefaultsOmitTheThemeLine() {
        XCTAssertFalse(GhosttyDefaultConfig.text(themes: nil).contains("theme ="))
        XCTAssertTrue(GhosttyDefaultConfig.text(themes: nil).contains("clipboard-write = ask"))
    }

    /// Dark stays the Arthur theme Casper has always shipped.
    func testDarkThemeIsArthur() {
        XCTAssertTrue(GhosttyDefaultConfig.darkTheme.contains("background = #1c1c1c"))
        XCTAssertTrue(GhosttyDefaultConfig.darkTheme.contains("palette = 0=#3d352a"))
        XCTAssertTrue(GhosttyDefaultConfig.lightTheme.contains("background = #ffffff"))
    }

    func testWriteOverwritesAnExistingFile() throws {
        let first = try GhosttyThemeFiles.write(to: directory)
        try "stale".write(to: first.light, atomically: true, encoding: .utf8)
        let second = try GhosttyThemeFiles.write(to: directory)
        XCTAssertEqual(try String(contentsOf: second.light, encoding: .utf8), GhosttyDefaultConfig.lightTheme)
        XCTAssertEqual(try String(contentsOf: second.dark, encoding: .utf8), GhosttyDefaultConfig.darkTheme)
    }

    func testWriteThrowsForAnUnwritableDirectory() throws {
        // A regular file where the directory should be: nothing can be created under it.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocker = directory.appendingPathComponent("blocker")
        try "x".write(to: blocker, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try GhosttyThemeFiles.write(to: blocker.appendingPathComponent("themes")))
    }

    // MARK: - libghostty round-trips

    /// libghostty's conditional state starts light, so a fresh config resolves
    /// to the light theme's background, with no diagnostics.
    func testLibghosttyLoadsTheThemesWithoutDiagnostics() throws {
        let config = try loadConfig(user: nil)
        defer { ghostty_config_free(config) }
        XCTAssertEqual(ghostty_config_diagnostics_count(config), 0)
        XCTAssertEqual(background(of: config), [0xff, 0xff, 0xff])
    }

    /// A user's single `theme` replaces Casper's outright.
    func testUserThemeReplacesOurs() throws {
        let userTheme = directory.appendingPathComponent("user-theme")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "background = #102030\n".write(to: userTheme, atomically: true, encoding: .utf8)
        let config = try loadConfig(user: "theme = \(userTheme.path)\n")
        defer { ghostty_config_free(config) }
        XCTAssertEqual(background(of: config), [0x10, 0x20, 0x30])
    }

    /// A user's explicit colour key beats Casper's theme.
    func testUserExplicitKeyBeatsOurTheme() throws {
        let config = try loadConfig(user: "background = #123456\n")
        defer { ghostty_config_free(config) }
        XCTAssertEqual(background(of: config), [0x12, 0x34, 0x56])
    }

    /// Mirrors `GhosttyRuntime.init`'s load order: Casper's defaults first, then
    /// (standing in for the user's files) `user`.
    private func loadConfig(user: String?) throws -> ghostty_config_t {
        let paths = try GhosttyThemeFiles.write(to: directory)
        let defaults = directory.appendingPathComponent("defaults.ghostty")
        try GhosttyDefaultConfig.text(themes: paths).write(to: defaults, atomically: true, encoding: .utf8)
        let config = try XCTUnwrap(ghostty_config_new())
        ghostty_config_load_file(config, defaults.path)
        if let user {
            let userFile = directory.appendingPathComponent("user.ghostty")
            try user.write(to: userFile, atomically: true, encoding: .utf8)
            ghostty_config_load_file(config, userFile.path)
        }
        ghostty_config_finalize(config)
        return config
    }

    private func background(of config: ghostty_config_t) -> [UInt8] {
        var color = ghostty_config_color_s()
        let key = "background"
        XCTAssertTrue(ghostty_config_get(config, &color, key, UInt(key.utf8.count)))
        return [color.r, color.g, color.b]
    }
}
