import AppKit
import Foundation
import GhosttyKit
import XCTest
import CasperTestSupport
@testable import CasperGhostty

/// Casper's built-in colours reach libghostty as two theme files behind one
/// conditional `theme` line, never as explicit keys: in Ghostty an explicit
/// colour key beats any theme, so explicit defaults would mask a user's own
/// `theme = …`.
final class GhosttyDefaultConfigTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(ghosttyInitialized, "ghostty_init failed")
        directory = makeTemporaryDirectory(prefix: "casper-theme-tests")
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

    /// Dark stays the Arthur palette and light the GitHub Light one; only the
    /// background is taken from the app.
    func testThemesKeepTheirPalettes() {
        XCTAssertTrue(GhosttyDefaultConfig.darkTheme(background: "#123456").contains("palette = 0=#3d352a"))
        XCTAssertTrue(GhosttyDefaultConfig.darkTheme(background: "#123456").contains("foreground = #ddeedd"))
        XCTAssertTrue(GhosttyDefaultConfig.lightTheme(background: "#123456").contains("palette = 0=#24292f"))
        XCTAssertTrue(GhosttyDefaultConfig.lightTheme(background: "#123456").contains("foreground = #1f2328"))
    }

    func testThemesUseTheGivenBackground() {
        XCTAssertTrue(GhosttyDefaultConfig.darkTheme(background: "#123456").contains("background = #123456\n"))
        XCTAssertTrue(GhosttyDefaultConfig.lightTheme(background: "#654321").contains("background = #654321\n"))
    }

    func testWrittenThemesCarryTheResolvedContentBackground() throws {
        let paths = try GhosttyThemeFiles.write(to: directory)
        let light = try String(contentsOf: paths.light, encoding: .utf8)
        let dark = try String(contentsOf: paths.dark, encoding: .utf8)
        XCTAssertTrue(light.contains("background = \(GhosttyDefaultConfig.contentBackgroundHex(for: .aqua))\n"))
        XCTAssertTrue(dark.contains("background = \(GhosttyDefaultConfig.contentBackgroundHex(for: .darkAqua))\n"))
    }

    func testContentBackgroundHexIsLowercaseRGBAndDiffersPerAppearance() throws {
        let light = GhosttyDefaultConfig.contentBackgroundHex(for: .aqua)
        let dark = GhosttyDefaultConfig.contentBackgroundHex(for: .darkAqua)
        for hex in [light, dark] {
            XCTAssertNotNil(hex.wholeMatch(of: /#[0-9a-f]{6}/), hex)
        }
        XCTAssertNotEqual(light, dark)
    }

    /// Independent of the implementation's helper: the OS owns the colour and it
    /// differs across macOS versions, so the expectation is computed here.
    func testContentBackgroundHexMatchesTextBackgroundColor() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            var expected: String?
            try XCTUnwrap(NSAppearance(named: name)).performAsCurrentDrawingAppearance {
                let color = NSColor.textBackgroundColor.usingColorSpace(.sRGB)
                expected = color.map { c in
                    let bytes = [c.redComponent, c.greenComponent, c.blueComponent].map {
                        min(max(Int(($0 * 255).rounded()), 0), 255)
                    }
                    return String(format: "#%02x%02x%02x", bytes[0], bytes[1], bytes[2])
                }
            }
            XCTAssertEqual(GhosttyDefaultConfig.contentBackgroundHex(for: name), try XCTUnwrap(expected))
        }
    }

    func testWriteOverwritesAnExistingFile() throws {
        let first = try GhosttyThemeFiles.write(to: directory)
        let original = try String(contentsOf: first.light, encoding: .utf8)
        try "stale".write(to: first.light, atomically: true, encoding: .utf8)
        let second = try GhosttyThemeFiles.write(to: directory)
        XCTAssertEqual(try String(contentsOf: second.light, encoding: .utf8), original)
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
        XCTAssertEqual(background(of: config), contentBackgroundBytes(for: .aqua))
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
