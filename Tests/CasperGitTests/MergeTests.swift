import XCTest
import Clibgit2
@testable import CasperGit

final class MergeTests: XCTestCase {
    private var root: URL!
    private var repoDir: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("casper-merge-\(UUID().uuidString)")
        repoDir = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Commit `content` to `filename` in `repo`'s working tree, onto its current HEAD.
    /// Mirrors `GitFixture.repository(at:)`'s libgit2 sequence for a non-initial commit.
    private func commit(
        _ repo: Repository, filename: String, content: String, message: String
    ) throws {
        let workdir = try XCTUnwrap(repo.workdirPath)
        try content.write(
            to: URL(fileURLWithPath: workdir).appendingPathComponent(filename),
            atomically: true, encoding: .utf8)

        var index: OpaquePointer?
        try gitCheck(git_repository_index(&index, repo.pointer))
        defer { git_index_free(index) }
        try gitCheck(git_index_add_bypath(index, filename))
        try gitCheck(git_index_write(index))

        var treeOid = git_oid()
        try gitCheck(git_index_write_tree(&treeOid, index))
        var tree: OpaquePointer?
        try gitCheck(git_tree_lookup(&tree, repo.pointer, &treeOid))
        defer { git_tree_free(tree) }

        var headRef: OpaquePointer?
        try gitCheck(git_repository_head(&headRef, repo.pointer))
        defer { git_reference_free(headRef) }
        var parent: OpaquePointer?
        try gitCheck(git_reference_peel(&parent, headRef, GIT_OBJECT_COMMIT))
        defer { git_object_free(parent) }

        var signature: UnsafeMutablePointer<git_signature>?
        try gitCheck(git_signature_now(&signature, "Casper Test", "test@casper.local"))
        defer { git_signature_free(signature) }

        var commitOid = git_oid()
        var parents: [OpaquePointer?] = [parent]
        try gitCheck(parents.withUnsafeMutableBufferPointer { buf in
            git_commit_create(
                &commitOid, repo.pointer, "HEAD",
                signature, signature, nil, message, tree, 1, buf.baseAddress)
        })
    }

    /// The tip commit OID (hex string) of local branch `name`.
    private func tipOID(_ repo: Repository, branch name: String) throws -> String {
        var ref: OpaquePointer?
        try gitCheck(git_branch_lookup(&ref, repo.pointer, name, GIT_BRANCH_LOCAL))
        defer { git_reference_free(ref) }
        var commit: OpaquePointer?
        try gitCheck(git_reference_peel(&commit, ref, GIT_OBJECT_COMMIT))
        defer { git_object_free(commit) }
        var buf = [Int8](repeating: 0, count: 41)
        git_oid_tostr(&buf, 41, git_object_id(commit))
        let oidBytes = buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return String(decoding: oidBytes, as: UTF8.self)
    }

    func testMergeAlreadyUpToDateWritesNothing() throws {
        let repo = try GitFixture.repository(at: repoDir.path)
        let main = try repo.headBranchName()
        _ = try repo.addWorktree(name: "feature", atPath: root.appendingPathComponent("feature").path, basedOn: nil)
        let beforeOID = try tipOID(repo, branch: main)

        let outcome = try repo.mergeBranchHeadless("feature", into: main, message: "merge")

        XCTAssertEqual(outcome, .upToDate)
        XCTAssertEqual(try tipOID(repo, branch: main), beforeOID)
    }

    func testMergeFastForwardableHistoryCreatesMergeCommit() throws {
        let repo = try GitFixture.repository(at: repoDir.path)
        let main = try repo.headBranchName()
        let wtInfo = try repo.addWorktree(
            name: "feature", atPath: root.appendingPathComponent("feature").path, basedOn: nil)
        let featureRepo = try Repository.open(atPath: wtInfo.path)
        try commit(featureRepo, filename: "feature.txt", content: "new\n", message: "add feature")

        let outcome = try repo.mergeBranchHeadless("feature", into: main, message: "merge feature")

        guard case .merged = outcome else { return XCTFail("expected a merge commit") }
        // Always a merge commit (--no-ff), never a checkout: the tree carries the new
        // file even though the target's working directory is untouched.
        XCTAssertEqual(try repo.fileTextAtHead(path: "feature.txt"), "new\n")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: repoDir.appendingPathComponent("feature.txt").path))
    }

    func testMergeDivergentHistoryAutoMerges() throws {
        let repo = try GitFixture.repository(at: repoDir.path)
        let main = try repo.headBranchName()
        let wtInfo = try repo.addWorktree(
            name: "feature", atPath: root.appendingPathComponent("feature").path, basedOn: nil)
        let featureRepo = try Repository.open(atPath: wtInfo.path)
        try commit(featureRepo, filename: "feature.txt", content: "from feature\n", message: "add feature file")
        try commit(repo, filename: "main.txt", content: "from main\n", message: "add main file")

        let outcome = try repo.mergeBranchHeadless("feature", into: main, message: "merge feature")

        guard case .merged = outcome else { return XCTFail("expected a merge commit") }
        XCTAssertEqual(try repo.fileTextAtHead(path: "feature.txt"), "from feature\n")
        XCTAssertEqual(try repo.fileTextAtHead(path: "main.txt"), "from main\n")
    }

    func testMergeConflictingHistoryThrowsAndWritesNothing() throws {
        let repo = try GitFixture.repository(at: repoDir.path)
        let main = try repo.headBranchName()
        let wtInfo = try repo.addWorktree(
            name: "feature", atPath: root.appendingPathComponent("feature").path, basedOn: nil)
        let featureRepo = try Repository.open(atPath: wtInfo.path)
        try commit(featureRepo, filename: "README.md", content: "from feature\n", message: "feature edits readme")
        try commit(repo, filename: "README.md", content: "from main\n", message: "main edits readme")
        let beforeOID = try tipOID(repo, branch: main)

        XCTAssertThrowsError(
            try repo.mergeBranchHeadless("feature", into: main, message: "merge feature")
        ) { error in
            XCTAssertTrue(error is MergeConflictError)
        }
        XCTAssertEqual(try tipOID(repo, branch: main), beforeOID)
    }

    func testMergeMissingTargetBranchThrows() throws {
        let repo = try GitFixture.repository(at: repoDir.path)
        _ = try repo.addWorktree(name: "feature", atPath: root.appendingPathComponent("feature").path, basedOn: nil)

        XCTAssertThrowsError(
            try repo.mergeBranchHeadless("feature", into: "ghost-branch", message: "merge"))
    }
}
