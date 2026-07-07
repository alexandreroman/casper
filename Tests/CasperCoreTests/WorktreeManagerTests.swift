import Clibgit2
import Foundation
import XCTest
@testable import CasperCore
@testable import CasperGit

final class WorktreeManagerTests: XCTestCase {
    private var root: URL!
    private var repoDir: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("casper-mgr-\(UUID().uuidString)")
        repoDir = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(
            at: repoDir, withIntermediateDirectories: true)
        try seedRepository(at: repoDir.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Seed a repo with one commit via CasperGit (mirrors the CasperGit fixture).
    private func seedRepository(at path: String) throws {
        let repo = try Repository.initialize(atPath: path)
        let readme = URL(fileURLWithPath: path).appendingPathComponent("README.md")
        try "seed\n".write(to: readme, atomically: true, encoding: .utf8)
        try makeInitialCommit(repo: repo, path: path)
    }

    func testCreateProducesWorktreeAndBranch() throws {
        let wtPath = root.appendingPathComponent("feature").path
        let created = try WorktreeManager.create(
            repoPath: repoDir.path, name: "feature",
            worktreePath: wtPath, base: nil)

        XCTAssertEqual(created.name, "feature")
        XCTAssertEqual(created.branch, "feature")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wtPath))
        XCTAssertEqual(
            URL(fileURLWithPath: created.path).standardizedFileURL.path,
            URL(fileURLWithPath: wtPath).standardizedFileURL.path)
    }

    func testCreateRejectsCheckedOutBranch() throws {
        let repo = try Repository.open(atPath: repoDir.path)
        let head = try repo.headBranchName()
        let wtPath = root.appendingPathComponent("dup").path

        XCTAssertThrowsError(
            try WorktreeManager.create(
                repoPath: repoDir.path, name: head,
                worktreePath: wtPath, base: nil)
        ) { error in
            XCTAssertEqual(
                (error as? WorktreeError)?.reason, .branchAlreadyCheckedOut)
        }
    }

    func testCreateRejectsMissingRepository() {
        XCTAssertThrowsError(
            try WorktreeManager.create(
                repoPath: root.appendingPathComponent("none").path,
                name: "x",
                worktreePath: root.appendingPathComponent("x").path, base: nil)
        ) { error in
            XCTAssertEqual(
                (error as? WorktreeError)?.reason, .repositoryNotFound)
        }
    }

    func testListReflectsCreatedWorktrees() throws {
        let wtPath = root.appendingPathComponent("feature").path
        _ = try WorktreeManager.create(
            repoPath: repoDir.path, name: "feature",
            worktreePath: wtPath, base: nil)

        let listed = try WorktreeManager.list(repoPath: repoDir.path)
        XCTAssertEqual(listed.map(\.name), ["feature"])
    }

    func testRemoveDeletesWorktree() throws {
        let wtPath = root.appendingPathComponent("feature").path
        _ = try WorktreeManager.create(
            repoPath: repoDir.path, name: "feature",
            worktreePath: wtPath, base: nil)

        try WorktreeManager.remove(repoPath: repoDir.path, name: "feature")

        XCTAssertEqual(try WorktreeManager.list(repoPath: repoDir.path).count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wtPath))
    }

    func testIsCleanReflectsWorkingTree() throws {
        XCTAssertTrue(try WorktreeManager.isClean(repoPath: repoDir.path))
        let extra = repoDir.appendingPathComponent("dirty.txt")
        try "x".write(to: extra, atomically: true, encoding: .utf8)
        XCTAssertFalse(try WorktreeManager.isClean(repoPath: repoDir.path))
    }

    func testMergeMergesFeatureIntoBaseBranch() throws {
        let base = try Repository.open(atPath: repoDir.path).headBranchName()
        let wtPath = root.appendingPathComponent("feature").path
        _ = try WorktreeManager.create(
            repoPath: repoDir.path, name: "feature", worktreePath: wtPath, base: nil)
        try commitFile(
            atPath: wtPath, filename: "feature.txt", content: "new\n", message: "add feature")

        let outcome = try WorktreeManager.merge(
            repoPath: repoDir.path, branch: "feature", into: base, message: "merge feature")

        guard case .merged = outcome else { return XCTFail("expected a merge commit") }
        XCTAssertEqual(
            try Repository.open(atPath: repoDir.path).fileTextAtHead(path: "feature.txt"), "new\n")
    }

    func testMergeAlreadyUpToDateReturnsNoCommit() throws {
        let base = try Repository.open(atPath: repoDir.path).headBranchName()
        let wtPath = root.appendingPathComponent("feature").path
        _ = try WorktreeManager.create(
            repoPath: repoDir.path, name: "feature", worktreePath: wtPath, base: nil)

        let outcome = try WorktreeManager.merge(
            repoPath: repoDir.path, branch: "feature", into: base, message: "merge feature")

        XCTAssertEqual(outcome, .upToDate)
    }

    func testMergeConflictThrowsMergeConflictReason() throws {
        let base = try Repository.open(atPath: repoDir.path).headBranchName()
        let wtPath = root.appendingPathComponent("feature").path
        _ = try WorktreeManager.create(
            repoPath: repoDir.path, name: "feature", worktreePath: wtPath, base: nil)
        try commitFile(
            atPath: wtPath, filename: "README.md", content: "from feature\n", message: "feature readme")
        try commitFile(
            atPath: repoDir.path, filename: "README.md", content: "from main\n", message: "main readme")

        XCTAssertThrowsError(
            try WorktreeManager.merge(
                repoPath: repoDir.path, branch: "feature", into: base, message: "merge feature")
        ) { error in
            XCTAssertEqual((error as? WorktreeError)?.reason, .mergeConflict)
        }
    }
}

/// Throw a plain `NSError` when a libgit2 call returns a negative code. `gitCheck`
/// itself is `internal` to `CasperGit`; this local equivalent keeps the commit
/// helper below a literal copy of `GitFixture.repository`'s libgit2 sequence
/// without pulling `GitError` construction into a test file.
private func check(_ code: Int32) throws {
    if code < 0 {
        throw NSError(domain: "git", code: Int(code))
    }
}

/// Create one commit on `repo`'s working tree at `path`, using the same
/// libgit2 sequence as `Tests/CasperGitTests/GitFixture.swift`: stage the
/// README already written by the caller, build a tree from the index, and
/// commit it onto HEAD. `repo` must already be open on an initialized,
/// unborn repository — this helper does not call `Repository.initialize`.
private func makeInitialCommit(repo: Repository, path: String) throws {
    var index: OpaquePointer?
    try check(git_repository_index(&index, repo.pointer))
    defer { git_index_free(index) }
    try check(git_index_add_bypath(index, "README.md"))
    try check(git_index_write(index))

    var treeOid = git_oid()
    try check(git_index_write_tree(&treeOid, index))
    var tree: OpaquePointer?
    try check(git_tree_lookup(&tree, repo.pointer, &treeOid))
    defer { git_tree_free(tree) }

    var signature: UnsafeMutablePointer<git_signature>?
    try check(git_signature_now(&signature, "Casper Test", "test@casper.local"))
    defer { git_signature_free(signature) }

    // Swift cannot import the variadic `git_commit_create_v`, so use the
    // array-based `git_commit_create` with zero parents (initial commit).
    var commitOid = git_oid()
    try check(git_commit_create(
        &commitOid, repo.pointer, "HEAD",
        signature, signature, nil, "Initial commit", tree, 0, nil))
}

/// Commit `content` to `filename` in the working tree at `repoPath`, onto its
/// current HEAD. Used to simulate independent commits on a linked worktree and
/// on the primary repo path for merge-scenario setup.
private func commitFile(
    atPath repoPath: String, filename: String, content: String, message: String
) throws {
    let repo = try Repository.open(atPath: repoPath)
    try content.write(
        to: URL(fileURLWithPath: repoPath).appendingPathComponent(filename),
        atomically: true, encoding: .utf8)

    var index: OpaquePointer?
    try check(git_repository_index(&index, repo.pointer))
    defer { git_index_free(index) }
    try check(git_index_add_bypath(index, filename))
    try check(git_index_write(index))

    var treeOid = git_oid()
    try check(git_index_write_tree(&treeOid, index))
    var tree: OpaquePointer?
    try check(git_tree_lookup(&tree, repo.pointer, &treeOid))
    defer { git_tree_free(tree) }

    var headRef: OpaquePointer?
    try check(git_repository_head(&headRef, repo.pointer))
    defer { git_reference_free(headRef) }
    var parent: OpaquePointer?
    try check(git_reference_peel(&parent, headRef, GIT_OBJECT_COMMIT))
    defer { git_object_free(parent) }

    var signature: UnsafeMutablePointer<git_signature>?
    try check(git_signature_now(&signature, "Casper Test", "test@casper.local"))
    defer { git_signature_free(signature) }

    var commitOid = git_oid()
    var parentPointer = parent
    try check(git_commit_create(
        &commitOid, repo.pointer, "HEAD",
        signature, signature, nil, message, tree, 1, &parentPointer))
}
