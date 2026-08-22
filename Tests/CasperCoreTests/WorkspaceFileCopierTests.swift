import Foundation
import XCTest
@testable import CasperCore

final class WorkspaceFileCopierTests: XCTestCase {
    private var root: URL!
    private var sourceDir: URL!
    private var destinationDir: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("casper-copier-\(UUID().uuidString)")
        sourceDir = root.appendingPathComponent("source")
        destinationDir = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Some tests strip all permissions off a source file; restore write access
        // before recursive removal so cleanup itself doesn't fail.
        if let sourceDir {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: sourceDir.path)
        }
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ content: String, to relativePath: String, in dir: URL) throws {
        let url = dir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    func testCopiesLiteralPatternMatch() throws {
        try write("SECRET=1\n", to: ".env", in: sourceDir)

        let copied = try WorkspaceFileCopier.copy(
            patterns: [".env"], from: sourceDir.path, to: destinationDir.path)

        XCTAssertEqual(copied, [".env"])
        XCTAssertEqual(
            try String(contentsOf: destinationDir.appendingPathComponent(".env"), encoding: .utf8),
            "SECRET=1\n")
    }

    func testCopiesWildcardPatternMatch() throws {
        try write("a\n", to: "monfichier1.txt", in: sourceDir)
        try write("b\n", to: "monfichier2.txt", in: sourceDir)
        try write("c\n", to: "other.txt", in: sourceDir)

        let copied = try WorkspaceFileCopier.copy(
            patterns: ["monfichier*.txt"], from: sourceDir.path, to: destinationDir.path)

        XCTAssertEqual(Set(copied), ["monfichier1.txt", "monfichier2.txt"])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destinationDir.appendingPathComponent("other.txt").path))
    }

    func testCopiesMatchInNestedSubdirectory() throws {
        try write("nested\n", to: "config/.env", in: sourceDir)

        let copied = try WorkspaceFileCopier.copy(
            patterns: [".env"], from: sourceDir.path, to: destinationDir.path)

        XCTAssertEqual(copied, ["config/.env"])
        XCTAssertEqual(
            try String(
                contentsOf: destinationDir.appendingPathComponent("config/.env"), encoding: .utf8),
            "nested\n")
    }

    func testSkipsGitDirectory() throws {
        try write("SECRET=1\n", to: ".git/.env", in: sourceDir)

        let copied = try WorkspaceFileCopier.copy(
            patterns: [".env"], from: sourceDir.path, to: destinationDir.path)

        XCTAssertEqual(copied, [])
    }

    /// Exclusions name immediate children of the source root only, so a directory
    /// of the same name nested deeper is still walked.
    func testSkipsExcludedTopLevelDirectoriesOnly() throws {
        try write("pruned\n", to: "node_modules/.env", in: sourceDir)
        try write("kept\n", to: "src/node_modules/.env", in: sourceDir)

        let copied = try WorkspaceFileCopier.copy(
            patterns: [".env"], from: sourceDir.path, to: destinationDir.path,
            skippingTopLevelDirectories: ["node_modules"])

        XCTAssertEqual(copied, ["src/node_modules/.env"])
    }

    func testPreservesPermissionBits() throws {
        try write("SECRET=1\n", to: ".env", in: sourceDir)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: sourceDir.appendingPathComponent(".env").path)

        _ = try WorkspaceFileCopier.copy(
            patterns: [".env"], from: sourceDir.path, to: destinationDir.path)

        let attrs = try FileManager.default.attributesOfItem(
            atPath: destinationDir.appendingPathComponent(".env").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testNoMatchesReturnsEmptyResultWithoutError() throws {
        try write("hello\n", to: "README.md", in: sourceDir)

        let copied = try WorkspaceFileCopier.copy(
            patterns: [".env"], from: sourceDir.path, to: destinationDir.path)

        XCTAssertEqual(copied, [])
    }

    func testUnreadableSourceFileThrows() throws {
        try write("SECRET=1\n", to: ".env", in: sourceDir)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: sourceDir.appendingPathComponent(".env").path)

        XCTAssertThrowsError(
            try WorkspaceFileCopier.copy(
                patterns: [".env"], from: sourceDir.path, to: destinationDir.path))
    }
}
