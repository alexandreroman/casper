import Clibgit2
import Foundation
import XCTest
@testable import CasperCore
@testable import CasperGit

final class WorktreeManagerTests: XCTestCase {
    private var root: URL!
    private var repoDir: URL!
    /// A directory created OUTSIDE `root` by the symlink-containment test; torn
    /// down separately so it survives (and is cleaned up after) an assertion
    /// failure inside the test body.
    private var externalDir: URL?

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
        if let externalDir {
            try? FileManager.default.removeItem(at: externalDir)
        }
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

    func testCreateCopiesDefaultPatternFilesIntoNewWorktree() throws {
        try "SECRET=1\n".write(
            to: repoDir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        let wtPath = root.appendingPathComponent("feature").path

        try WorktreeManager.create(
            repoPath: repoDir.path, name: "feature", worktreePath: wtPath, base: nil)

        XCTAssertEqual(
            try String(
                contentsOf: URL(fileURLWithPath: wtPath).appendingPathComponent(".env"),
                encoding: .utf8),
            "SECRET=1\n")
    }

    func testCreateRollsBackWorktreeAndBranchOnCopyFailure() throws {
        try "SECRET=1\n".write(
            to: repoDir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: repoDir.appendingPathComponent(".env").path)
        defer {
            // Restore read access so tearDown's directory removal doesn't fail.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: repoDir.appendingPathComponent(".env").path)
        }
        let wtPath = root.appendingPathComponent("feature").path

        XCTAssertThrowsError(
            try WorktreeManager.create(
                repoPath: repoDir.path, name: "feature", worktreePath: wtPath, base: nil)
        ) { error in
            guard case .fileCopyFailed = (error as? WorktreeError)?.reason else {
                return XCTFail("expected .fileCopyFailed, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: wtPath))
        XCTAssertEqual(try WorktreeManager.list(repoPath: repoDir.path).count, 0)
        let repo = try Repository.open(atPath: repoDir.path)
        XCTAssertFalse(try repo.branchExists("feature"))
    }

    func testCreateOnARepositoryWithoutCommitsSaysSoInCaspersWords() throws {
        // `git init` and nothing else: HEAD is unborn, so there is no commit for a
        // worktree to be checked out at. The user must not read libgit2's
        // "revspec 'HEAD' not found" for that.
        let unbornDir = root.appendingPathComponent("unborn")
        try FileManager.default.createDirectory(at: unbornDir, withIntermediateDirectories: true)
        _ = try Repository.initialize(atPath: unbornDir.path)
        let wtPath = root.appendingPathComponent("feature").path

        XCTAssertThrowsError(
            try WorktreeManager.create(
                repoPath: unbornDir.path, name: "feature", worktreePath: wtPath, base: nil)
        ) { error in
            XCTAssertEqual((error as? WorktreeError)?.reason, .repositoryHasNoCommits)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: wtPath))
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
        try WorktreeManager.create(
            repoPath: repoDir.path, name: "feature",
            worktreePath: wtPath, base: nil)

        let listed = try WorktreeManager.list(repoPath: repoDir.path)
        XCTAssertEqual(listed.map(\.name), ["feature"])
    }

    func testRegisteredNameResolvesTheAdminEntryByPath() throws {
        let wtPath = root.appendingPathComponent("feature").path
        try WorktreeManager.create(
            repoPath: repoDir.path, name: "feature", worktreePath: wtPath, base: nil)

        XCTAssertEqual(
            WorktreeManager.registeredName(repoPath: repoDir.path, worktreePath: wtPath),
            "feature")
        // A path git knows nothing about — the caller falls back to the branch name.
        XCTAssertNil(WorktreeManager.registeredName(
            repoPath: repoDir.path, worktreePath: root.appendingPathComponent("ghost").path))
    }

    func testRemoveDeletesWorktree() throws {
        let wtPath = root.appendingPathComponent("feature").path
        try WorktreeManager.create(
            repoPath: repoDir.path, name: "feature",
            worktreePath: wtPath, base: nil)

        try WorktreeManager.remove(repoPath: repoDir.path, name: "feature", worktreePath: wtPath)

        XCTAssertEqual(try WorktreeManager.list(repoPath: repoDir.path).count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wtPath))
    }

    /// Failure mode 1: a read-only directory (mode 0555) inside the working tree
    /// — the classic Go module / package-cache case — blocks libgit2's own
    /// recursive rmdir. The robust removal must still delete the directory.
    func testRemoveDeletesWorktreeWithReadOnlyEntries() throws {
        let wtPath = root.appendingPathComponent("feature").path
        try WorktreeManager.create(
            repoPath: repoDir.path, name: "feature", worktreePath: wtPath, base: nil)

        // A read-only directory containing a read-only file: unlinking the file
        // needs write permission on its 0555 parent, which the owner lacks.
        let cache = URL(fileURLWithPath: wtPath).appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try "cached\n".write(
            to: cache.appendingPathComponent("locked.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: cache.path)
        defer {
            // Restore write access so a failed assertion still lets tearDown clean up.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: cache.path)
        }

        try WorktreeManager.remove(repoPath: repoDir.path, name: "feature", worktreePath: wtPath)
        try WorktreeManager.deleteBranch(repoPath: repoDir.path, name: "feature")

        XCTAssertFalse(FileManager.default.fileExists(atPath: wtPath))
        XCTAssertFalse(try Repository.open(atPath: repoDir.path).branchExists("feature"))
    }

    /// Failure mode 2: a half-completed prior prune deletes the libgit2 admin
    /// entry before the working tree, orphaning the directory. On retry the admin
    /// entry is already gone, so the removal must fall back to deleting the
    /// directory itself and tolerate the missing metadata without error.
    func testRemoveDeletesOrphanedWorktreeDirectory() throws {
        let wtPath = root.appendingPathComponent("feature").path
        try WorktreeManager.create(
            repoPath: repoDir.path, name: "feature", worktreePath: wtPath, base: nil)

        // Simulate the prior half-prune: drop only the admin entry, leaving the
        // working-tree directory on disk.
        let adminEntry = repoDir.appendingPathComponent(".git/worktrees/feature")
        try FileManager.default.removeItem(at: adminEntry)
        XCTAssertTrue(FileManager.default.fileExists(atPath: wtPath))

        XCTAssertNoThrow(
            try WorktreeManager.remove(repoPath: repoDir.path, name: "feature", worktreePath: wtPath))

        XCTAssertFalse(FileManager.default.fileExists(atPath: wtPath))
    }

    /// Safety-critical containment: a symlink INSIDE the worktree pointing at a
    /// target OUTSIDE it must never be followed while permissions are restored
    /// for removal. After removal the external target must still exist with its
    /// mode untouched (not relaxed to 0700/0600), and the worktree gone.
    func testRemoveDoesNotFollowSymlinkOutOfWorktree() throws {
        // An external target with a distinctive, restrictive mode, living OUTSIDE
        // `root` so only an errant chmod-through-symlink could change it.
        let external = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("casper-external-\(UUID().uuidString)")
        externalDir = external
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: external.path)
        let externalFile = external.appendingPathComponent("keep.txt")
        try "external\n".write(to: externalFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: externalFile.path)
        let dirModeBefore = try mode(of: external.path)
        let fileModeBefore = try mode(of: externalFile.path)

        let wtPath = root.appendingPathComponent("feature").path
        try WorktreeManager.create(
            repoPath: repoDir.path, name: "feature", worktreePath: wtPath, base: nil)
        try FileManager.default.createSymbolicLink(
            at: URL(fileURLWithPath: wtPath).appendingPathComponent("escape-link"),
            withDestinationURL: external)

        try WorktreeManager.remove(repoPath: repoDir.path, name: "feature", worktreePath: wtPath)
        try WorktreeManager.deleteBranch(repoPath: repoDir.path, name: "feature")

        XCTAssertFalse(FileManager.default.fileExists(atPath: wtPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalFile.path))
        XCTAssertEqual(try mode(of: external.path), dirModeBefore)
        XCTAssertEqual(try mode(of: externalFile.path), fileModeBefore)
        XCTAssertEqual(dirModeBefore, 0o700)
        XCTAssertEqual(fileModeBefore, 0o644)
    }

    /// Containment for the ROOT itself: when the path handed to
    /// `forceRemoveDirectory` is a symlink to an out-of-tree target, restoring
    /// permissions must not chmod through it. Only the link is unlinked; the
    /// external target keeps its mode.
    func testForceRemoveDirectoryDoesNotChmodSymlinkRootTarget() throws {
        let external = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("casper-external-\(UUID().uuidString)")
        externalDir = external
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: external.path)
        let modeBefore = try mode(of: external.path)

        let link = root.appendingPathComponent("root-link").path
        try FileManager.default.createSymbolicLink(
            atPath: link, withDestinationPath: external.path)

        try WorktreeManager.forceRemoveDirectory(at: link)

        XCTAssertFalse(FileManager.default.fileExists(atPath: link))
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
        XCTAssertEqual(try mode(of: external.path), modeBefore)
        XCTAssertEqual(modeBefore, 0o755)
    }

    /// Idempotency: `forceRemoveDirectory` on an already-missing path is a no-op
    /// success, never an error.
    func testForceRemoveDirectoryOnMissingPathSucceeds() throws {
        let missing = root.appendingPathComponent("does-not-exist").path
        XCTAssertNoThrow(try WorktreeManager.forceRemoveDirectory(at: missing))
    }

    /// The POSIX permission bits of the item at `path`, masked to the standard
    /// 12 mode bits so comparisons ignore incidental higher-order flags.
    private func mode(of path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? Int)
        return permissions & 0o7777
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
        try WorktreeManager.create(
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
        try WorktreeManager.create(
            repoPath: repoDir.path, name: "feature", worktreePath: wtPath, base: nil)

        let outcome = try WorktreeManager.merge(
            repoPath: repoDir.path, branch: "feature", into: base, message: "merge feature")

        XCTAssertEqual(outcome, .upToDate)
    }

    func testMergeConflictThrowsMergeConflictReason() throws {
        let base = try Repository.open(atPath: repoDir.path).headBranchName()
        let wtPath = root.appendingPathComponent("feature").path
        try WorktreeManager.create(
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

    func testResyncWorkingTreeSyncsToNewHead() throws {
        let base = try Repository.open(atPath: repoDir.path).headBranchName()
        let wtPath = root.appendingPathComponent("feature").path
        try WorktreeManager.create(
            repoPath: repoDir.path, name: "feature", worktreePath: wtPath, base: nil)
        try commitFile(
            atPath: wtPath, filename: "feature.txt", content: "new\n", message: "add feature")
        _ = try WorktreeManager.merge(
            repoPath: repoDir.path, branch: "feature", into: base, message: "merge feature")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: repoDir.appendingPathComponent("feature.txt").path))

        try WorktreeManager.resyncWorkingTree(repoPath: repoDir.path)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: repoDir.appendingPathComponent("feature.txt").path))
    }

    private func writeRepoConfig(_ json: String) throws {
        try json.write(
            to: repoDir.appendingPathComponent(".casper.json"),
            atomically: true, encoding: .utf8)
    }

    func testCreateHonorsCopyPatternsFromConfig() throws {
        try "SECRET=1\n".write(
            to: repoDir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try "OTHER=1\n".write(
            to: repoDir.appendingPathComponent(".env.local"), atomically: true, encoding: .utf8)
        try writeRepoConfig(#"{"workspace":{"copyFiles":[".env"]}}"#)
        let wtPath = root.appendingPathComponent("feature").path

        try WorktreeManager.create(
            repoPath: repoDir.path, name: "feature", worktreePath: wtPath, base: nil)

        let wt = URL(fileURLWithPath: wtPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: wt.appendingPathComponent(".env").path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: wt.appendingPathComponent(".env.local").path))
    }

    func testCreateWithEmptyCopyPatternsCopiesNothing() throws {
        try "SECRET=1\n".write(
            to: repoDir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try writeRepoConfig(#"{"workspace":{"copyFiles":[]}}"#)
        let wtPath = root.appendingPathComponent("feature").path

        try WorktreeManager.create(
            repoPath: repoDir.path, name: "feature", worktreePath: wtPath, base: nil)

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: wtPath).appendingPathComponent(".env").path))
    }

    func testCreateWithInvalidConfigThrowsAndLeavesNothing() throws {
        try writeRepoConfig("not json")
        let wtPath = root.appendingPathComponent("feature").path

        XCTAssertThrowsError(
            try WorktreeManager.create(
                repoPath: repoDir.path, name: "feature", worktreePath: wtPath, base: nil)
        ) { error in
            guard case .configInvalid = (error as? WorktreeError)?.reason else {
                return XCTFail("expected .configInvalid, got \(error)")
            }
        }

        // Nothing half-created: no worktree directory, no branch.
        XCTAssertFalse(FileManager.default.fileExists(atPath: wtPath))
        let branches = try WorktreeManager.list(repoPath: repoDir.path).map(\.name)
        XCTAssertFalse(branches.contains("feature"))
    }

    func testConfigInvalidErrorMessageMentionsFile() throws {
        let error = WorktreeError(.configInvalid("bad token at line 1"))
        XCTAssertEqual(error.localizedDescription, "Invalid .casper.json: bad token at line 1")
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
