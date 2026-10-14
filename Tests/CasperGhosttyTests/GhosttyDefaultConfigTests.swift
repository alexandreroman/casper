import AppKit
import Foundation
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
}
