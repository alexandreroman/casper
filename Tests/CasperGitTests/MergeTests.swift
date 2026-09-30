import Foundation
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
        try GitFixture.commit(featureRepo, Data("new\n".utf8), to: "feature.txt", message: "add feature")

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
        try GitFixture.commit(
            featureRepo, Data("from feature\n".utf8), to: "feature.txt", message: "add feature file")
        try GitFixture.commit(repo, Data("from main\n".utf8), to: "main.txt", message: "add main file")

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
        try GitFixture.commit(
            featureRepo, Data("from feature\n".utf8), to: "README.md", message: "feature edits readme")
        try GitFixture.commit(repo, Data("from main\n".utf8), to: "README.md", message: "main edits readme")
        let beforeOID = try tipOID(repo, branch: main)

        XCTAssertThrowsError(
            try repo.mergeBranchHeadless("feature", into: main, message: "merge feature")
        ) { error in
            XCTAssertTrue(error is MergeConflictError)
        }
        XCTAssertEqual(try tipOID(repo, branch: main), beforeOID)
    }

    func testMergeUnrelatedHistoriesThrowsDedicatedError() throws {
        let repo = try GitFixture.repository(at: repoDir.path)
        let main = try repo.headBranchName()
        try makeOrphanBranch(repo, name: "orphan")
        let beforeOID = try tipOID(repo, branch: main)

        XCTAssertThrowsError(
            try repo.mergeBranchHeadless("orphan", into: main, message: "merge orphan")
        ) { error in
            XCTAssertEqual(
                error as? MergeUnrelatedHistoriesError,
                MergeUnrelatedHistoriesError(sourceBranch: "orphan", targetBranch: main),
                "expected a dedicated unrelated-histories error, got \(error)")
        }
        XCTAssertEqual(try tipOID(repo, branch: main), beforeOID)
    }

    /// Point branch `name` at a fresh *root* commit (no parents) reusing HEAD's tree,
    /// so it shares no ancestor with the default branch — `git_merge_base` then
    /// reports GIT_ENOTFOUND.
    private func makeOrphanBranch(_ repo: Repository, name: String) throws {
        var headRef: OpaquePointer?
        try gitCheck(git_repository_head(&headRef, repo.pointer))
        defer { git_reference_free(headRef) }
        var tree: OpaquePointer?
        try gitCheck(git_reference_peel(&tree, headRef, GIT_OBJECT_TREE))
        defer { git_object_free(tree) }

        var signature: UnsafeMutablePointer<git_signature>?
        try gitCheck(git_signature_now(&signature, "Casper Test", "test@casper.local"))
        defer { git_signature_free(signature) }

        var commitOid = git_oid()
        try gitCheck(git_commit_create(
            &commitOid, repo.pointer, "refs/heads/\(name)",
            signature, signature, nil, "Unrelated root commit", tree, 0, nil))
    }

    func testMergeMissingTargetBranchThrows() throws {
        let repo = try GitFixture.repository(at: repoDir.path)
        _ = try repo.addWorktree(name: "feature", atPath: root.appendingPathComponent("feature").path, basedOn: nil)

        XCTAssertThrowsError(
            try repo.mergeBranchHeadless("feature", into: "ghost-branch", message: "merge"))
    }

    func testForceCheckoutHeadSyncsWorkdirToNewHead() throws {
        let repo = try GitFixture.repository(at: repoDir.path)
        let main = try repo.headBranchName()
        let wtInfo = try repo.addWorktree(
            name: "feature", atPath: root.appendingPathComponent("feature").path, basedOn: nil)
        let featureRepo = try Repository.open(atPath: wtInfo.path)
        try GitFixture.commit(featureRepo, Data("new\n".utf8), to: "feature.txt", message: "add feature")

        _ = try repo.mergeBranchHeadless("feature", into: main, message: "merge feature")
        // Confirms the precondition: right after a headless merge, the target's
        // working directory has NOT picked up the new file yet.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: repoDir.appendingPathComponent("feature.txt").path))

        try repo.forceCheckoutHead()

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: repoDir.appendingPathComponent("feature.txt").path))
    }
}
