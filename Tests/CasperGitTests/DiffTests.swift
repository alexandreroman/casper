import XCTest
import Clibgit2
@testable import CasperGit

final class DiffTests: XCTestCase {
    private func tempDir() -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("casper-diff-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testCleanRepoHasNoFiles() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try GitFixture.repository(at: dir.path)  // one commit, clean
        XCTAssertTrue(try repo.diffWorkdirToHead().files.isEmpty)
    }

    func testModifiedFileProducesHunk() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try GitFixture.repository(at: dir.path)  // README.md = "casper fixture\n"
        try "casper CHANGED\n".write(
            to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let diff = try repo.diffWorkdirToHead()
        XCTAssertEqual(diff.files.count, 1)
        let file = diff.files[0]
        XCTAssertEqual(file.status, .modified)
        XCTAssertEqual(file.newPath, "README.md")
        XCTAssertFalse(file.isBinary)
        XCTAssertEqual(file.hunks.count, 1)
        let kinds = file.hunks[0].lines.map(\.kind)
        XCTAssertTrue(kinds.contains(.deletion))
        XCTAssertTrue(kinds.contains(.addition))
    }

    func testUntrackedFileIsAddedWithAdditions() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try GitFixture.repository(at: dir.path)
        try "new\ncontent\n".write(
            to: dir.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        let file = try repo.diffWorkdirToHead().files.first { $0.newPath == "new.txt" }
        XCTAssertEqual(file?.status, .added)
        // An untracked text file must not be misclassified as binary.
        XCTAssertFalse(file?.isBinary ?? true)
        let lines = file?.hunks.flatMap(\.lines) ?? []
        // Real addition hunks must be present, carrying the file's actual content.
        XCTAssertFalse(lines.isEmpty)
        XCTAssertTrue(lines.allSatisfy { $0.kind == .addition })
        XCTAssertTrue(lines.allSatisfy { $0.oldLineNumber == nil })
        XCTAssertTrue(lines.contains { $0.content == "new" })
        XCTAssertTrue(lines.contains { $0.content == "content" })
    }

    func testFilesAreSortedAlphabetically() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try GitFixture.repository(at: dir.path)
        // Create untracked files deliberately out of alphabetical order.
        for name in ["zebra.txt", "apple.txt", "mango.txt"] {
            try "\(name)\n".write(
                to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let paths = try repo.diffWorkdirToHead().files.map { $0.newPath }
        XCTAssertEqual(paths, paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        XCTAssertEqual(paths, ["apple.txt", "mango.txt", "zebra.txt"])
    }

    func testDeletedFileIsDeletion() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try GitFixture.repository(at: dir.path)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("README.md"))
        let file = try repo.diffWorkdirToHead().files.first { $0.oldPath == "README.md" }
        XCTAssertEqual(file?.status, .deleted)
        XCTAssertTrue((file?.hunks.flatMap(\.lines) ?? []).allSatisfy { $0.kind == .deletion })
    }

    func testUnbornHeadDiffsWholeTreeAsAdded() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try Repository.initialize(atPath: dir.path)  // no commit -> unborn HEAD
        try "hello\n".write(
            to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let file = try repo.diffWorkdirToHead().files.first { $0.newPath == "a.txt" }
        XCTAssertEqual(file?.status, .added)
    }

    func testBinaryFileHasNoHunks() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try GitFixture.repository(at: dir.path)
        var bytes = Data([0x00, 0x01, 0x02, 0x00, 0xff, 0xfe])
        bytes.append(contentsOf: [0x00, 0x00])
        try bytes.write(to: dir.appendingPathComponent("blob.bin"))
        let file = try repo.diffWorkdirToHead().files.first { $0.newPath == "blob.bin" }
        XCTAssertEqual(file?.isBinary, true)
        XCTAssertTrue(file?.hunks.isEmpty ?? false)
    }

    func testChmodOnlyIsNotBinary() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try GitFixture.repository(at: dir.path)
        // Flip the executable bit without touching the file's content.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: dir.appendingPathComponent("README.md").path)

        let diff = try repo.diffWorkdirToHead()
        // No file must ever be reported as binary — whether or not this libgit2
        // build surfaces the mode-only change as a delta.
        XCTAssertTrue(diff.files.allSatisfy { !$0.isBinary })
        // When the mode change does surface, it must be a plain modification.
        if let readme = diff.files.first(where: { $0.newPath == "README.md" }) {
            XCTAssertEqual(readme.status, .modified)
            XCTAssertFalse(readme.isBinary)
        }
    }

    func testNoTrailingNewlineOmitsEOFNLMarker() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try GitFixture.repository(at: dir.path)  // README.md = "casper fixture\n"
        // Overwrite with content that has no final newline.
        try "line one\nline two".write(
            to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let file = try repo.diffWorkdirToHead().files.first { $0.newPath == "README.md" }
        let lines = file?.hunks.flatMap(\.lines) ?? []
        // The "\ No newline at end of file" note must not leak in as a content row.
        XCTAssertFalse(lines.contains { $0.content == "\\ No newline at end of file" })
        XCTAssertFalse(lines.contains { $0.content.contains("No newline at end of file") })
        // The real changed content still comes through unaffected by the skip.
        XCTAssertTrue(lines.contains { $0.content == "line two" })
    }
}
