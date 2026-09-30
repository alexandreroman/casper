import Foundation
import XCTest
import Clibgit2
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

    // MARK: - Helpers

    /// A path inside the fixture's working tree.
    private func url(_ path: String) -> URL {
        directory.appendingPathComponent(path)
    }

    /// Twenty distinct numbered lines: enough shared content that editing one of them
    /// keeps a renamed copy well above libgit2's 50% similarity threshold.
    private static let twentyLines = (1...20).map { "line \($0)\n" }.joined()

    /// Two kilobytes of NUL-laced bytes: binary to libgit2, and varied enough — its
    /// newline bytes cut it into many distinct chunks — for the similarity check to
    /// pair a lightly edited copy with the original.
    private static let binaryBlob: Data = {
        var bytes = Data([0x00, 0xff, 0x00, 0xfe])
        for i in 0..<2048 { bytes.append(UInt8(truncatingIfNeeded: i * 7)) }
        return bytes
    }()

    // MARK: - Tests

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

    // MARK: - Renames

    func testUnstagedRenameIsOneRenamedFile() throws {
        // A plain `mv`, index untouched: libgit2 sees a deleted README.md and an
        // untracked NOTES.md, which must pair up into a single rename.
        try FileManager.default.moveItem(at: url("README.md"), to: url("NOTES.md"))

        let diff = try repo.diffWorkdirToHead()
        XCTAssertEqual(diff.files.count, 1)
        let file = try XCTUnwrap(diff.files.first)
        XCTAssertEqual(file.status, .renamed)
        XCTAssertEqual(file.oldPath, "README.md")
        XCTAssertEqual(file.newPath, "NOTES.md")
        XCTAssertEqual(file.id, "NOTES.md")
        XCTAssertFalse(file.isBinary)
        // A pure rename moves no content, so there is nothing to show but the paths.
        XCTAssertTrue(file.hunks.isEmpty)
    }

    func testStagedRenameIsOneRenamedFile() throws {
        // `git mv`, spelled out through the index.
        try FileManager.default.moveItem(at: url("README.md"), to: url("NOTES.md"))
        try GitFixture.stage(repo, adding: ["NOTES.md"], removing: ["README.md"])

        let diff = try repo.diffWorkdirToHead()
        XCTAssertEqual(diff.files.count, 1)
        let file = try XCTUnwrap(diff.files.first)
        XCTAssertEqual(file.status, .renamed)
        XCTAssertEqual(file.oldPath, "README.md")
        XCTAssertEqual(file.newPath, "NOTES.md")
        XCTAssertEqual(file.id, "NOTES.md")
        XCTAssertFalse(file.isBinary)
        XCTAssertTrue(file.hunks.isEmpty)
    }

    func testRenameWithAnEditCarriesOnlyTheEdit() throws {
        try GitFixture.commit(repo, Data(Self.twentyLines.utf8), to: "lines.txt", message: "Add lines")
        try FileManager.default.moveItem(at: url("lines.txt"), to: url("renamed.txt"))
        let edited = Self.twentyLines.replacingOccurrences(of: "line 10\n", with: "line ten\n")
        try edited.write(to: url("renamed.txt"), atomically: true, encoding: .utf8)

        let diff = try repo.diffWorkdirToHead()
        XCTAssertEqual(diff.files.count, 1)
        let file = try XCTUnwrap(diff.files.first)
        XCTAssertEqual(file.status, .renamed)
        XCTAssertEqual(file.oldPath, "lines.txt")
        XCTAssertEqual(file.newPath, "renamed.txt")
        XCTAssertFalse(file.isBinary)
        let changed = file.hunks.flatMap(\.lines).filter { $0.kind != .context }
        XCTAssertEqual(changed.map(\.kind), [.deletion, .addition])
        XCTAssertEqual(changed.map(\.content), ["line 10", "line ten"])
        // The edit alone, not the whole file deleted then re-added.
        XCTAssertEqual(diff.insertions, 1)
        XCTAssertEqual(diff.deletions, 1)
    }

    func testDissimilarAddAndDeleteStaySeparate() throws {
        try FileManager.default.removeItem(at: url("README.md"))
        try "nothing in common with the fixture\n".write(
            to: url("other.txt"), atomically: true, encoding: .utf8)

        let statuses = try repo.diffWorkdirToHead().files.map { "\($0.status):\($0.newPath)" }
        XCTAssertEqual(statuses, ["added:other.txt", "deleted:README.md"])
    }

    /// The deleted README's single line, followed by blank lines: libgit2's
    /// similarity metric skips whitespace after a newline, so to it this is the
    /// README's exact content at any size — and a source of 127 bytes or less skips
    /// its size-ratio check. Only the size cap can keep the two apart.
    private func writeReadmeLookalike(to path: String, size: Int) throws {
        var contents = Data("casper fixture\n".utf8)
        contents.append(Data(repeating: UInt8(ascii: "\n"), count: size - contents.count))
        try contents.write(to: url(path))
    }

    func testReadmeLookalikeUnderTheSizeCapPairsAsARename() throws {
        // The control for the test below: the same content, small, does pair up.
        try FileManager.default.removeItem(at: url("README.md"))
        try writeReadmeLookalike(to: "lookalike.txt", size: 64)

        let statuses = try repo.diffWorkdirToHead().files.map { "\($0.status):\($0.newPath)" }
        XCTAssertEqual(statuses, ["renamed:lookalike.txt"])
    }

    func testUntrackedFileOverTheSizeCapIsNeverARenameTarget() throws {
        // Hashing a target's content for similarity reads it in full, which the cap
        // exists to prevent on every refresh — so an oversized file stays unpaired.
        try FileManager.default.removeItem(at: url("README.md"))
        try writeReadmeLookalike(to: "lookalike.txt", size: Int(Repository.maxDiffFileSize) + 1)

        let files = try repo.diffWorkdirToHead().files
        XCTAssertEqual(files.map { "\($0.status):\($0.newPath)" }, ["added:lookalike.txt", "deleted:README.md"])
        // Past the cap libgit2 marks the file binary without loading it.
        XCTAssertEqual(files.first { $0.newPath == "lookalike.txt" }?.isBinary, true)
    }

    func testRenameDetectionIgnoresTheUserConfig() throws {
        // Three deleted sources; the renamed file's is the last one libgit2 visits.
        // With `diff.renameLimit = 1` honoured it would stop after two, and with
        // `diff.renames = false` it would not look at all.
        try GitFixture.commit(repo, Data("alpha\n".utf8), to: "a.txt", message: "Add a")
        try GitFixture.commit(repo, Data("bravo\n".utf8), to: "b.txt", message: "Add b")
        try GitFixture.commit(repo, Data(Self.twentyLines.utf8), to: "c.txt", message: "Add c")
        var config: OpaquePointer?
        try gitCheck(git_repository_config(&config, repo.pointer))
        defer { git_config_free(config) }
        try gitCheck(git_config_set_bool(config, "diff.renames", 0))
        try gitCheck(git_config_set_int32(config, "diff.renameLimit", 1))

        try FileManager.default.removeItem(at: url("a.txt"))
        try FileManager.default.removeItem(at: url("b.txt"))
        try FileManager.default.moveItem(at: url("c.txt"), to: url("d.txt"))

        let statuses = try repo.diffWorkdirToHead().files.map { "\($0.status):\($0.oldPath)" }
        XCTAssertEqual(statuses, ["deleted:a.txt", "deleted:b.txt", "renamed:c.txt"])
    }

    func testFailedRenamePassLeavesTheDeltasUnpaired() throws {
        // Rename detection is best-effort: a target it cannot read mid-pass costs the
        // pairing, not the diff. Driven below `diffWorkdirToHead`, because a target
        // unreadable from the start already fails patch generation on its own.
        try FileManager.default.removeItem(at: url("README.md"))
        try writeReadmeLookalike(to: "unreadable.txt", size: 64)

        var tree: OpaquePointer?
        try gitCheck(git_revparse_single(&tree, repo.pointer, "HEAD^{tree}"))
        defer { git_object_free(tree) }
        var options = git_diff_options()
        try gitCheck(git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION)))
        options.flags = GIT_DIFF_INCLUDE_UNTRACKED.rawValue
        var diff: OpaquePointer?
        try gitCheck(git_diff_tree_to_workdir_with_index(&diff, repo.pointer, tree, &options))
        defer { git_diff_free(diff) }

        // Readable when the diff listed it, locked by the time its content is hashed.
        let unreadablePath = url("unreadable.txt").path
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadablePath)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadablePath) }
        Repository.detectRenames(in: try XCTUnwrap(diff))

        let statuses = (0..<git_diff_num_deltas(diff)).map { git_diff_get_delta(diff, $0)?.pointee.status }
        XCTAssertEqual(statuses, [GIT_DELTA_DELETED, GIT_DELTA_UNTRACKED])
    }

    func testRenameBudgetFollowsGitsDefaultRenameLimit() {
        let limit = Repository.renameLimit
        XCTAssertTrue(Repository.isRenameDetectionAffordable(sources: limit, targets: limit))
        XCTAssertFalse(Repository.isRenameDetectionAffordable(sources: limit + 1, targets: limit))
        XCTAssertTrue(Repository.isRenameDetectionAffordable(sources: 1, targets: limit * limit))
        // Nothing to pair on one side: nothing to run.
        XCTAssertFalse(Repository.isRenameDetectionAffordable(sources: 0, targets: 10))
        XCTAssertFalse(Repository.isRenameDetectionAffordable(sources: 10, targets: 0))
    }

    /// A renamed binary file is flagged binary by libgit2 itself: unlike an added
    /// file, it has a blob on the HEAD side, so `buildFile` needs no fallback for it.
    func testRenamedAndModifiedBinaryFileIsBinary() throws {
        try GitFixture.commit(repo, Self.binaryBlob, to: "blob.bin", message: "Add a blob")
        try FileManager.default.moveItem(at: url("blob.bin"), to: url("moved.bin"))
        var modified = Self.binaryBlob
        modified[100] = 0x42
        modified.append(contentsOf: [0x00, 0x01])
        try modified.write(to: url("moved.bin"))

        let diff = try repo.diffWorkdirToHead()
        XCTAssertEqual(diff.files.count, 1)
        let file = try XCTUnwrap(diff.files.first)
        XCTAssertEqual(file.status, .renamed)
        XCTAssertEqual(file.oldPath, "blob.bin")
        XCTAssertEqual(file.newPath, "moved.bin")
        XCTAssertTrue(file.isBinary)
        XCTAssertTrue(file.hunks.isEmpty)
    }

    func testPureBinaryRenameIsBinary() throws {
        try GitFixture.commit(repo, Self.binaryBlob, to: "blob.bin", message: "Add a blob")
        try FileManager.default.moveItem(at: url("blob.bin"), to: url("moved.bin"))

        let file = try XCTUnwrap(repo.diffWorkdirToHead().files.first)
        XCTAssertEqual(file.status, .renamed)
        XCTAssertTrue(file.isBinary)
    }
}
