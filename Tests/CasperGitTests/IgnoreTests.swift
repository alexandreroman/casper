import XCTest
@testable import CasperGit

final class IgnoreTests: XCTestCase {
    func testIgnoredTopLevelDirectories() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("casper-ignore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let repo = try GitFixture.repository(at: dir.path)

        let gitignore = dir.appendingPathComponent(".gitignore")
        try "node_modules/\nbuild/\n".write(to: gitignore, atomically: true, encoding: .utf8)

        // Each directory needs a file inside so it exists on disk.
        for name in ["node_modules", "build", "src"] {
            let subdir = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
            try "content\n".write(
                to: subdir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        }

        // Compare on the last path components so the assertion is symlink-agnostic: libgit2 reports
        // canonical working-dir paths (/private/var/...) while the temp dir is a /var/... symlink.
        let dirs = try repo.ignoredTopLevelDirectories()
        XCTAssertEqual(dirs.map { URL(fileURLWithPath: $0).lastPathComponent }, ["build", "node_modules"])
        XCTAssertFalse(dirs.contains { $0.hasSuffix("/src") })
        XCTAssertFalse(dirs.contains { $0.hasSuffix("/.git") })

        XCTAssertTrue(try repo.isPathIgnored("node_modules"))
        XCTAssertFalse(try repo.isPathIgnored("src"))
    }
}
