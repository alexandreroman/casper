import XCTest
import Clibgit2
import CasperTestSupport
@testable import CasperGit

final class WorktreeTests: XCTestCase {
    private var root: URL!
    private var repoDir: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("casper-wt-\(UUID().uuidString)")
        repoDir = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(
            at: repoDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAddWorktreeCreatesBranchAndDirectory() throws {
        let repo = try GitFixture.repository(at: repoDir.path)
        let wtPath = root.appendingPathComponent("feature").path

        let info = try repo.addWorktree(
            name: "feature", atPath: wtPath, basedOn: nil)

        XCTAssertEqual(info.name, "feature")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wtPath))
        XCTAssertTrue(try repo.branchExists("feature"))
        XCTAssertTrue(try repo.isBranchCheckedOut("feature"))
    }

    func testListAndLookupWorktree() throws {
        let repo = try GitFixture.repository(at: repoDir.path)
        let wtPath = root.appendingPathComponent("feature").path
        _ = try repo.addWorktree(name: "feature", atPath: wtPath, basedOn: nil)

        XCTAssertEqual(try repo.worktreeNames(), ["feature"])

        let info = try repo.worktreeInfo(name: "feature")
        XCTAssertEqual(info.name, "feature")
        XCTAssertEqual(
            URL(fileURLWithPath: info.path).standardizedFileURL.path,
            URL(fileURLWithPath: wtPath).standardizedFileURL.path)
    }

    func testLookupUnknownWorktreeThrows() throws {
        let repo = try GitFixture.repository(at: repoDir.path)
        XCTAssertThrowsError(try repo.worktreeInfo(name: "ghost"))
    }

    func testAddWorktreeBasedOnExplicitRef() throws {
        let repo = try GitFixture.repository(at: repoDir.path)
        let base = try repo.headBranchName()  // the fixture's default branch
        let wtPath = root.appendingPathComponent("from-base").path

        let info = try repo.addWorktree(
            name: "from-base", atPath: wtPath, basedOn: base)

        XCTAssertEqual(info.name, "from-base")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wtPath))
        XCTAssertTrue(try repo.branchExists("from-base"))
        XCTAssertTrue(try repo.isBranchCheckedOut("from-base"))
    }

    func testAddWorktreeRollsBackBranchAndAdminEntryWhenAddFails() throws {
        let repo = try GitFixture.repository(at: repoDir.path)
        let wtPath = root.appendingPathComponent("blocked").path

        // Pre-create the target as a non-empty directory so git_worktree_add
        // fails AFTER git_branch_create has already created the branch.
        try FileManager.default.createDirectory(
            atPath: wtPath, withIntermediateDirectories: true)
        try "occupied".write(
            to: URL(fileURLWithPath: wtPath).appendingPathComponent("blocker.txt"),
            atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try repo.addWorktree(name: "blocked", atPath: wtPath, basedOn: nil))

        // The branch created before the failed add must have been rolled back,
        // so the operation stays idempotent and retryable.
        XCTAssertFalse(try repo.branchExists("blocked"))
        // So must the partial admin entry libgit2 created before the failure, or a
        // retry under the same name fails with "directory exists".
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.commonDirPath + "worktrees/blocked"))
        let retryPath = root.appendingPathComponent("blocked-2").path
        XCTAssertNoThrow(try repo.addWorktree(name: "blocked", atPath: retryPath, basedOn: nil))
    }

    /// A worktree registered under the name but checked out on another branch — what
    /// `git worktree add ../taken -b other` leaves — is not this call's to roll back.
    func testFailedAddLeavesAForeignWorktreeOfTheSameNameIntact() throws {
        let repo = try GitFixture.repository(at: repoDir.path)
        let foreignPath = root.appendingPathComponent("taken").path
        try addWorktree(to: repo, name: "taken", atPath: foreignPath, onNewBranch: "other")
        let foreignFile = URL(fileURLWithPath: foreignPath).appendingPathComponent("precious.txt")
        try "uncommitted work".write(to: foreignFile, atomically: true, encoding: .utf8)

        let casperPath = root.appendingPathComponent("casper-taken").path
        XCTAssertThrowsError(try repo.addWorktree(name: "taken", atPath: casperPath, basedOn: nil))

        XCTAssertTrue(FileManager.default.fileExists(atPath: foreignFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.commonDirPath + "worktrees/taken"))
        XCTAssertFalse(try repo.branchExists("taken"))
    }

    /// The common directory is the repository's identity: a linked worktree reports
    /// the SAME one as its main working tree, even though their git dirs differ.
    func testWorktreeSharesCommonDirWithMainWorkingTree() throws {
        let repo = try GitFixture.repository(at: repoDir.path)
        let wtPath = root.appendingPathComponent("feature").path
        _ = try repo.addWorktree(name: "feature", atPath: wtPath, basedOn: nil)

        let worktreeRepo = try Repository.open(atPath: wtPath)

        XCTAssertEqual(
            URL(fileURLWithPath: worktreeRepo.commonDirPath).standardizedFileURL.path,
            URL(fileURLWithPath: repo.commonDirPath).standardizedFileURL.path)
        XCTAssertNotEqual(
            URL(fileURLWithPath: worktreeRepo.gitDirPath).standardizedFileURL.path,
            URL(fileURLWithPath: repo.gitDirPath).standardizedFileURL.path)
        XCTAssertTrue(worktreeRepo.isLinkedWorktree)
        XCTAssertFalse(repo.isLinkedWorktree)
    }

    func testPruneRemovesWorktree() throws {
        let repo = try GitFixture.repository(at: repoDir.path)
        let wtPath = root.appendingPathComponent("feature").path
        _ = try repo.addWorktree(name: "feature", atPath: wtPath, basedOn: nil)

        try repo.pruneWorktree(name: "feature")

        XCTAssertEqual(try repo.worktreeNames(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: wtPath))
    }

    /// Register a worktree whose name and branch differ, which `addWorktree` never does.
    private func addWorktree(
        to repo: Repository, name: String, atPath path: String, onNewBranch branch: String
    ) throws {
        var commit: OpaquePointer?
        defer { git_object_free(commit) }
        try gitCheck(git_revparse_single(&commit, repo.pointer, "HEAD^{commit}"))
        var branchRef: OpaquePointer?
        defer { git_reference_free(branchRef) }
        try gitCheck(git_branch_create(&branchRef, repo.pointer, branch, commit, 0))

        var options = git_worktree_add_options()
        try gitCheck(git_worktree_add_options_init(&options, UInt32(GIT_WORKTREE_ADD_OPTIONS_VERSION)))
        options.ref = branchRef
        var worktree: OpaquePointer?
        defer { git_worktree_free(worktree) }
        try gitCheck(git_worktree_add(&worktree, repo.pointer, name, path, &options))
    }
}
