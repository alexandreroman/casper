import AppKit
import XCTest
@testable import CasperGhostty
import CasperTestSupport
@testable import CasperUI

final class AppearanceTests: XCTestCase {
    func testIsDarkMatchesTheAppearanceFamily() {
        XCTAssertTrue(NSAppearance(named: .darkAqua)!.isDark)
        XCTAssertTrue(NSAppearance(named: .vibrantDark)!.isDark)
        XCTAssertFalse(NSAppearance(named: .aqua)!.isDark)
        XCTAssertFalse(NSAppearance(named: .vibrantLight)!.isDark)
    }

    /// The runtime rewrites its theme files on every scheme switch, so files that
    /// reappear after being deleted are the trace of the model's call reaching it.
    @MainActor
    func testApplyColorSchemeForwardsToTheRuntime() throws {
        let directory = makeTemporaryDirectory(prefix: "casper-appearance-themes")
        let model = makeModel()
        model.runtime = try GhosttyRuntime(themeDirectory: directory, loadUserFiles: { _ in })
        try FileManager.default.removeItem(at: directory)

        model.applyColorScheme(dark: true)

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("casper-dark").path))
    }
}
