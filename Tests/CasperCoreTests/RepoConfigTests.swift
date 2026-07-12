import Foundation
import XCTest
@testable import CasperCore

final class RepoConfigTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("casper-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeConfig(_ json: String) throws {
        try json.write(
            to: root.appendingPathComponent(".casper.json"), atomically: true, encoding: .utf8)
    }

    func testNoFileReturnsNil() throws {
        XCTAssertNil(try RepoConfig.load(fromRepoRoot: root.path))
    }

    func testExplicitPatternsAreDecoded() throws {
        try writeConfig(#"{"workspace":{"copyPatterns":[".env"]}}"#)
        let config = try XCTUnwrap(try RepoConfig.load(fromRepoRoot: root.path))
        XCTAssertEqual(config.copyPatterns(default: [".env", ".env.local"]), [".env"])
    }

    func testEmptyPatternsCopyNothing() throws {
        try writeConfig(#"{"workspace":{"copyPatterns":[]}}"#)
        let config = try XCTUnwrap(try RepoConfig.load(fromRepoRoot: root.path))
        XCTAssertEqual(config.copyPatterns(default: [".env"]), [])
    }

    func testMissingCopyPatternsKeyFallsBackToDefaults() throws {
        try writeConfig(#"{"workspace":{}}"#)
        let config = try XCTUnwrap(try RepoConfig.load(fromRepoRoot: root.path))
        XCTAssertEqual(config.copyPatterns(default: [".env", ".env.local"]), [".env", ".env.local"])
    }

    func testMissingWorkspaceKeyFallsBackToDefaults() throws {
        try writeConfig(#"{}"#)
        let config = try XCTUnwrap(try RepoConfig.load(fromRepoRoot: root.path))
        XCTAssertEqual(config.copyPatterns(default: [".env"]), [".env"])
    }

    func testUnknownKeysAreTolerated() throws {
        try writeConfig(#"{"workspace":{"copyPatterns":[".env"],"scripts":{}},"other":1}"#)
        let config = try XCTUnwrap(try RepoConfig.load(fromRepoRoot: root.path))
        XCTAssertEqual(config.copyPatterns(default: []), [".env"])
    }

    func testGarbageJSONThrows() throws {
        try writeConfig("not json at all")
        XCTAssertThrowsError(try RepoConfig.load(fromRepoRoot: root.path)) { error in
            XCTAssertTrue(error is RepoConfigError)
        }
    }

    func testWrongTypeThrows() throws {
        try writeConfig(#"{"workspace":{"copyPatterns":5}}"#)
        XCTAssertThrowsError(try RepoConfig.load(fromRepoRoot: root.path)) { error in
            XCTAssertTrue(error is RepoConfigError)
        }
    }

    func testDecodeFailureReasonIsUserFriendly() throws {
        try writeConfig("not json at all")
        XCTAssertThrowsError(try RepoConfig.load(fromRepoRoot: root.path)) { error in
            let reason = (error as? RepoConfigError)?.reason ?? ""
            XCTAssertFalse(reason.isEmpty)
            XCTAssertFalse(reason.contains("DecodingError"))
            XCTAssertFalse(reason.contains("Context("))
        }
    }

    func testTypeMismatchReasonMentionsKeyPath() throws {
        try writeConfig(#"{"workspace":{"copyPatterns":5}}"#)
        XCTAssertThrowsError(try RepoConfig.load(fromRepoRoot: root.path)) { error in
            let reason = (error as? RepoConfigError)?.reason ?? ""
            XCTAssertTrue(reason.contains("copyPatterns"), "reason was: \(reason)")
        }
    }

    func testScriptsDecodeAndLookup() throws {
        try writeConfig(#"{"workspace":{"scripts":{"setup":"npm i","run":"npm run dev"}}}"#)
        let config = try XCTUnwrap(try RepoConfig.load(fromRepoRoot: root.path))
        XCTAssertEqual(config.setupScript(), "npm i")
        XCTAssertEqual(config.namedCommand("run"), "npm run dev")
    }

    func testTeardownScriptLookup() throws {
        try writeConfig(#"{"workspace":{"scripts":{"teardown":"docker compose down"}}}"#)
        let config = try XCTUnwrap(try RepoConfig.load(fromRepoRoot: root.path))
        XCTAssertEqual(config.teardownScript(), "docker compose down")
    }

    func testNamedCommandRejectsReservedNames() throws {
        try writeConfig(#"{"workspace":{"scripts":{"setup":"npm i","teardown":"x"}}}"#)
        let config = try XCTUnwrap(try RepoConfig.load(fromRepoRoot: root.path))
        XCTAssertNil(config.namedCommand("setup"))
        XCTAssertNil(config.namedCommand("teardown"))
    }

    func testNamedCommandsExcludeReservedAndSortByName() throws {
        try writeConfig(#"""
        {"workspace":{"scripts":{"zeta":"z","setup":"s","alpha":"a","teardown":"t"}}}
        """#)
        let config = try XCTUnwrap(try RepoConfig.load(fromRepoRoot: root.path))
        XCTAssertEqual(
            config.namedCommands(),
            [RepoNamedCommand(name: "alpha", command: "a"),
             RepoNamedCommand(name: "zeta", command: "z")])
    }

    func testEmptyCommandIsSkipped() throws {
        try writeConfig(#"{"workspace":{"scripts":{"setup":"","run":""}}}"#)
        let config = try XCTUnwrap(try RepoConfig.load(fromRepoRoot: root.path))
        XCTAssertNil(config.setupScript())
        XCTAssertNil(config.namedCommand("run"))
        XCTAssertEqual(config.namedCommands(), [])
    }

    func testNoScriptsSectionYieldsNoScripts() throws {
        try writeConfig(#"{"workspace":{"copyPatterns":[".env"]}}"#)
        let config = try XCTUnwrap(try RepoConfig.load(fromRepoRoot: root.path))
        XCTAssertNil(config.setupScript())
        XCTAssertNil(config.teardownScript())
        XCTAssertNil(config.namedCommand("run"))
        XCTAssertEqual(config.namedCommands(), [])
        // copyPatterns still works alongside a missing scripts section.
        XCTAssertEqual(config.copyPatterns(default: [".env", ".env.local"]), [".env"])
    }

    func testReservedNamesConstant() throws {
        XCTAssertEqual(RepoScripts.reservedNames, ["setup", "teardown"])
    }
}
