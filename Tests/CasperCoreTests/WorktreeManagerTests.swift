import CasperTestSupport
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
        root = makeTemporaryDirectory(prefix: "casper-mgr")
        repoDir = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(
            at: repoDir, withIntermediateDirectories: true)
        try GitFixture.repository(at: repoDir.path)
    }

    override func tearDownWithError() throws {
        if let externalDir {
            try? FileManager.default.removeItem(at: externalDir)
        }
    }

    func testCreateProducesWorktreeAndBranch() throws {
        let wtPath = root.appendingPathComponent("feature").path
        try WorktreeManager.create(
            repoPath: repoDir.path, name: "feature",
            worktreePath: wtPath, base: nil)

        XCTAssertTrue(FileManager.default.fileExists(atPath: wtPath))
        let repo = try Repository.open(atPath: repoDir.path)
        XCTAssertTrue(try repo.branchExists("feature"))
        // The admin entry git registered has to point at the path that was asked for.
        let registered = try XCTUnwrap(
            WorktreeManager.list(repoPath: repoDir.path).first { $0.name == "feature" })
        XCTAssertEqual(
            URL(fileURLWithPath: registered.path).standardizedFileURL.path,
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

    /// A worktree registered under the name on another branch — what
    /// `git worktree add ../taken -b other` leaves — is refused in Casper's words
    /// rather than libgit2's "directory exists", and before any branch is created.
    func testCreateRejectsANameAnotherWorktreeAlreadyUses() throws {
        try GitFixture.registerWorktree(
            inRepoAt: repoDir.path, name: "taken",
            atPath: root.appendingPathComponent("taken").path, onNewBranch: "other")
        let wtPath = root.appendingPathComponent("casper-taken").path

        XCTAssertThrowsError(
            try WorktreeManager.create(
                repoPath: repoDir.path, name: "taken", worktreePath: wtPath, base: nil)
        ) { error in
            XCTAssertEqual((error as? WorktreeError)?.reason, .worktreeNameTaken)
            XCTAssertEqual(
                error.localizedDescription,
                "Git already has a worktree entry by that name in this repository. Pick another name, "
                    + "or run 'git worktree prune' if that worktree was deleted.")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: wtPath))
        XCTAssertFalse(try Repository.open(atPath: repoDir.path).branchExists("taken"))
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

    // MARK: - Reclaiming an editor leftover

    /// Create the directory at `url` and populate it with `files` — paths relative
    /// to it, whose intermediate directories are created as needed.
    private func populate(_ url: URL, with files: [String]) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for file in files {
            let fileURL = url.appendingPathComponent(file)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "x\n".write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    /// The real-world case: an IDE still holding a deleted worktree open re-creates
    /// its directory minutes later, writing nothing into it but its own metadata.
    func testDirectoryHoldingOnlyEditorMetadataIsDisposable() throws {
        let ghost = root.appendingPathComponent("ghost")
        try populate(ghost, with: [".idea/workspace.xml"])

        XCTAssertTrue(WorktreeManager.isDisposableLeftover(at: ghost.path, repoPath: repoDir.path))
    }

    func testEmptyDirectoryIsDisposable() throws {
        let ghost = root.appendingPathComponent("ghost")
        try populate(ghost, with: [])

        XCTAssertTrue(WorktreeManager.isDisposableLeftover(at: ghost.path, repoPath: repoDir.path))
    }

    /// A `.git` entry means a live — or half-pruned — worktree, never a leftover.
    func testDirectoryHoldingAGitEntryIsNotDisposable() throws {
        let ghost = root.appendingPathComponent("ghost")
        try populate(ghost, with: [".idea/workspace.xml", ".git"])

        XCTAssertFalse(WorktreeManager.isDisposableLeftover(at: ghost.path, repoPath: repoDir.path))
    }

    /// One file nobody else wrote is enough: the allow-list admits editor metadata
    /// only, so anything that could be the user's work protects the directory.
    func testDirectoryHoldingAProjectFileIsNotDisposable() throws {
        let ghost = root.appendingPathComponent("ghost")
        try populate(ghost, with: [".idea/workspace.xml", "README.md"])

        XCTAssertFalse(WorktreeManager.isDisposableLeftover(at: ghost.path, repoPath: repoDir.path))
    }

    /// The registration criterion on its own: the directory's contents are reduced
    /// to exactly what an editor leftover looks like, so only the repository's
    /// worktree list can still protect it.
    func testRegisteredWorktreePathIsNotDisposable() throws {
        let wtPath = root.appendingPathComponent("feature").path
        try WorktreeManager.create(
            repoPath: repoDir.path, name: "feature", worktreePath: wtPath, base: nil)
        let worktree = URL(fileURLWithPath: wtPath)
        for entry in try FileManager.default.contentsOfDirectory(atPath: wtPath) {
            try FileManager.default.removeItem(at: worktree.appendingPathComponent(entry))
        }
        try populate(worktree, with: [".idea/workspace.xml"])

        XCTAssertFalse(WorktreeManager.isDisposableLeftover(at: wtPath, repoPath: repoDir.path))
    }

    /// A repository that cannot be read reports no worktree anywhere — out of
    /// ignorance, not knowledge. That silence must never authorize a delete.
    func testDirectoryIsNotDisposableWhenTheWorktreeListingFails() throws {
        let ghost = root.appendingPathComponent("ghost")
        try populate(ghost, with: [".idea/workspace.xml"])
        let notARepo = root.appendingPathComponent("not-a-repo")
        try FileManager.default.createDirectory(at: notARepo, withIntermediateDirectories: true)

        XCTAssertFalse(WorktreeManager.isDisposableLeftover(at: ghost.path, repoPath: notARepo.path))
        // The very same directory IS disposable for a repository that can answer,
        // so the unreadable repository is what flipped the verdict.
        XCTAssertTrue(WorktreeManager.isDisposableLeftover(at: ghost.path, repoPath: repoDir.path))
    }

    /// Containment: a link is never followed, whatever its target holds.
    func testSymlinkIsNotDisposable() throws {
        let ghost = root.appendingPathComponent("ghost")
        try populate(ghost, with: [".idea/workspace.xml"])
        let link = root.appendingPathComponent("ghost-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: ghost)

        XCTAssertFalse(WorktreeManager.isDisposableLeftover(at: link.path, repoPath: repoDir.path))
    }

    func testClaimWorktreePathAcceptsAFreePathWithoutCreatingIt() {
        let free = root.appendingPathComponent("free").path

        XCTAssertTrue(WorktreeManager.claimWorktreePath(free, repoPath: repoDir.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: free))
    }

    func testClaimWorktreePathDeletesADisposableLeftover() throws {
        let ghost = root.appendingPathComponent("ghost")
        try populate(ghost, with: [".idea/workspace.xml"])

        XCTAssertTrue(WorktreeManager.claimWorktreePath(ghost.path, repoPath: repoDir.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ghost.path))
    }

    func testClaimWorktreePathLeavesAnOccupiedPathUntouched() throws {
        let occupied = root.appendingPathComponent("occupied")
        try populate(occupied, with: ["README.md"])

        XCTAssertFalse(WorktreeManager.claimWorktreePath(occupied.path, repoPath: repoDir.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: occupied.appendingPathComponent("README.md").path))
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
        try GitFixture.commit(
            atPath: wtPath, file: "feature.txt", contents: "new\n", message: "add feature")

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
        try GitFixture.commit(
            atPath: wtPath, file: "README.md", contents: "from feature\n", message: "feature readme")
        try GitFixture.commit(
            atPath: repoDir.path, file: "README.md", contents: "from main\n", message: "main readme")

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
        try GitFixture.commit(
            atPath: wtPath, file: "feature.txt", contents: "new\n", message: "add feature")
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
