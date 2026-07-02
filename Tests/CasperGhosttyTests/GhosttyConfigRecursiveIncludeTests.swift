import Foundation
import GhosttyKit
import XCTest
@testable import CasperGhostty

/// Proves that `ghostty_config_load_recursive_files` is what resolves `config-file`
/// includes. The runtime relies on it so a user's config that pulls in a theme via
/// `config-file = ...` is actually honored; without the call, includes are silently
/// dropped. See `GhosttyRuntime.init`.
final class GhosttyConfigRecursiveIncludeTests: XCTestCase {
    /// Config parsing touches libghostty global state, so mirror the runtime's one-time
    /// `ghostty_init`. The shared lazy `ghosttyInitialized` guarantees exactly-once.
    override func setUpWithError() throws {
        try XCTSkipUnless(ghosttyInitialized, "ghostty_init failed")
    }

    /// Baseline: loading only the top-level file (no recursive pass) leaves the
    /// `config-file` include unprocessed, so the include's bad key raises no diagnostic.
    func testIncludeIsIgnoredWithoutRecursiveLoad() throws {
        let files = try TempConfigFiles()
        defer { files.cleanUp() }

        let config = try XCTUnwrap(ghostty_config_new())
        defer { ghostty_config_free(config) }

        ghostty_config_load_file(config, files.mainPath)
        ghostty_config_finalize(config)

        XCTAssertEqual(
            ghostty_config_diagnostics_count(config), 0,
            "The include's invalid key must not be seen when the recursive pass is skipped"
        )
    }

    /// With the recursive pass, the `config-file` include is followed and its invalid
    /// key produces a diagnostic — exactly the behavior `GhosttyRuntime` depends on.
    func testIncludeIsProcessedWithRecursiveLoad() throws {
        let files = try TempConfigFiles()
        defer { files.cleanUp() }

        let config = try XCTUnwrap(ghostty_config_new())
        defer { ghostty_config_free(config) }

        ghostty_config_load_file(config, files.mainPath)
        ghostty_config_load_recursive_files(config)
        ghostty_config_finalize(config)

        XCTAssertGreaterThan(
            ghostty_config_diagnostics_count(config), 0,
            "The recursive pass must follow the config-file include and flag its invalid key"
        )
    }
}

/// A throwaway temp directory holding a main config that includes a second file whose
/// only setting is deliberately invalid, so processing the include is observable.
private struct TempConfigFiles {
    let directory: URL
    let mainPath: String

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("casper-ghostty-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let includeURL = directory.appendingPathComponent("include.ghostty")
        try "this-key-does-not-exist-xyz = 1\n".write(to: includeURL, atomically: true, encoding: .utf8)

        let mainURL = directory.appendingPathComponent("main.ghostty")
        try "config-file = \(includeURL.path)\n".write(to: mainURL, atomically: true, encoding: .utf8)
        mainPath = mainURL.path
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}
