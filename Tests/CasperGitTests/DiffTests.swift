import XCTest
@testable import CasperGit

final class DiffTests: XCTestCase {
    /// A throwaway working tree, holding the fixture repository every test diffs.
    private var directory: URL!
    /// The fixture repository: one commit, clean, `README.md` = "casper fixture\n".
    private var repo: Repository!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("casper-diff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        repo = try GitFixture.repository(at: directory.path)
    }

    override func tearDownWithError() throws {
        repo = nil
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        try super.tearDownWithError()
    }

    func testCleanRepoHasNoFiles() throws {
        XCTAssertTrue(try repo.diffWorkdirToHead().files.isEmpty)
    }

    func testModifiedFileProducesHunk() throws {
        try "casper CHANGED\n".write(
            to: directory.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
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
        try "new\ncontent\n".write(
            to: directory.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
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
        // Create untracked files deliberately out of alphabetical order.
        for name in ["zebra.txt", "apple.txt", "mango.txt"] {
            try "\(name)\n".write(
                to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let paths = try repo.diffWorkdirToHead().files.map { $0.newPath }
        XCTAssertEqual(paths, paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        XCTAssertEqual(paths, ["apple.txt", "mango.txt", "zebra.txt"])
    }

    func testDeletedFileIsDeletion() throws {
        try FileManager.default.removeItem(at: directory.appendingPathComponent("README.md"))
        let file = try repo.diffWorkdirToHead().files.first { $0.oldPath == "README.md" }
        XCTAssertEqual(file?.status, .deleted)
        // libgit2 mirrors `old_file.path` into `new_file.path` for a deletion (the two
        // only diverge for a rename), so a deletion still has a usable display path and
        // `GitDiffFile.id` never has to fall back to `oldPath`.
        XCTAssertEqual(file?.newPath, "README.md")
        XCTAssertTrue((file?.hunks.flatMap(\.lines) ?? []).allSatisfy { $0.kind == .deletion })
    }

    func testUnbornHeadDiffsWholeTreeAsAdded() throws {
        // A repository of its own: an unborn HEAD is the point here, and the shared
        // fixture already carries a commit.
        let unbornDirectory = directory.appendingPathComponent("unborn")
        try FileManager.default.createDirectory(at: unbornDirectory, withIntermediateDirectories: true)
        let unbornRepo = try Repository.initialize(atPath: unbornDirectory.path)
        try "hello\n".write(
            to: unbornDirectory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let file = try unbornRepo.diffWorkdirToHead().files.first { $0.newPath == "a.txt" }
        XCTAssertEqual(file?.status, .added)
    }

    func testBinaryFileHasNoHunks() throws {
        var bytes = Data([0x00, 0x01, 0x02, 0x00, 0xff, 0xfe])
        bytes.append(contentsOf: [0x00, 0x00])
        try bytes.write(to: directory.appendingPathComponent("blob.bin"))
        let file = try repo.diffWorkdirToHead().files.first { $0.newPath == "blob.bin" }
        XCTAssertEqual(file?.isBinary, true)
        XCTAssertTrue(file?.hunks.isEmpty ?? false)
    }

    func testChmodOnlyIsNotBinary() throws {
        // Flip the executable bit without touching the file's content.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: directory.appendingPathComponent("README.md").path)

        let diff = try repo.diffWorkdirToHead()
        // Not every libgit2 build reports a mode-only change as a delta. Without one
        // there is nothing to classify, and asserting over the empty list would pass
        // while covering nothing — so say so instead.
        guard let readme = diff.files.first(where: { $0.newPath == "README.md" }) else {
            throw XCTSkip("this libgit2 build does not surface a mode-only change as a delta")
        }
        XCTAssertEqual(readme.status, .modified)
        XCTAssertFalse(readme.isBinary)
    }

    func testNoTrailingNewlineOmitsEOFNLMarker() throws {
        // Overwrite the fixture's README with content that has no final newline.
        try "line one\nline two".write(
            to: directory.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let file = try repo.diffWorkdirToHead().files.first { $0.newPath == "README.md" }
        let lines = file?.hunks.flatMap(\.lines) ?? []
        // The "\ No newline at end of file" note must not leak in as a content row.
        XCTAssertFalse(lines.contains { $0.content == "\\ No newline at end of file" })
        XCTAssertFalse(lines.contains { $0.content.contains("No newline at end of file") })
        // The real changed content still comes through unaffected by the skip.
        XCTAssertTrue(lines.contains { $0.content == "line two" })
    }
}
