import XCTest
import Clibgit2
@testable import CasperGit

final class RepositoryTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("casper-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testInitializeCreatesRepository() throws {
        let repo = try Repository.initialize(atPath: tempDir.path)
        XCTAssertNotNil(repo.workdirPath)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: tempDir.appendingPathComponent(".git").path))
    }

    func testOpenExistingRepository() throws {
        _ = try Repository.initialize(atPath: tempDir.path)
        let reopened = try Repository.open(atPath: tempDir.path)
        // workdir is reported with a trailing slash by libgit2.
        XCTAssertEqual(
            URL(fileURLWithPath: reopened.workdirPath!).standardizedFileURL.path,
            tempDir.standardizedFileURL.path)
    }

    func testOpenNonRepositoryThrows() {
        XCTAssertThrowsError(try Repository.open(atPath: tempDir.path))
    }

    func testHeadBranchNameAfterFixture() throws {
        let repo = try GitFixture.repository(at: tempDir.path)
        let branch = try repo.headBranchName()
        XCTAssertFalse(branch.isEmpty)
    }

    func testHeadBranchNameOnUnbornHead() throws {
        // Freshly initialized repo with no commits: HEAD is unborn but the
        // branch name (e.g. "main"/"master") must still resolve so a space
        // promoted right after `git init` shows the branch, not the folder.
        let repo = try Repository.initialize(atPath: tempDir.path)
        let branch = try repo.headBranchName()
        XCTAssertFalse(branch.isEmpty)
    }

    /// Record a committer in the repository's **local** config, so
    /// `git_signature_default` resolves whatever the machine running the suite has (or
    /// does not have) configured globally.
    private func configureIdentity(in repo: Repository) throws {
        var config: OpaquePointer?
        defer { git_config_free(config) }  // before the call: free on the throw path too
        try gitCheck(git_repository_config(&config, repo.pointer))
        try gitCheck(git_config_set_string(config, "user.name", "Casper Test"))
        try gitCheck(git_config_set_string(config, "user.email", "test@casper.local"))
    }

    func testCreateInitialCommitWritesAnEmptyRootCommit() throws {
        let repo = try Repository.initialize(atPath: tempDir.path)
        try configureIdentity(in: repo)

        XCTAssertTrue(try repo.createInitialCommit())

        XCTAssertFalse(repo.isHeadUnborn)
        var head: OpaquePointer?
        defer { git_reference_free(head) }
        try gitCheck(git_repository_head(&head, repo.pointer))
        var commit: OpaquePointer?
        defer { git_commit_free(commit) }
        try gitCheck(git_reference_peel(&commit, head, GIT_OBJECT_COMMIT))

        XCTAssertEqual(String(cString: git_commit_message(commit)), "Init repository")
        XCTAssertEqual(git_commit_parentcount(commit), 0)
        var tree: OpaquePointer?
        defer { git_tree_free(tree) }
        try gitCheck(git_commit_tree(&tree, commit))
        XCTAssertEqual(git_tree_entrycount(tree), 0)
    }

    /// The commit is parentless, so writing it onto a branch that already points
    /// somewhere would move that branch to a second root commit and orphan every
    /// commit behind it. The method is public, so the refusal has to be its own.
    func testCreateInitialCommitRefusesARepositoryThatAlreadyHasHistory() throws {
        let repo = try Repository.initialize(atPath: tempDir.path)
        try configureIdentity(in: repo)
        XCTAssertTrue(try repo.createInitialCommit())
        let head = try headCommitID(of: repo)

        XCTAssertFalse(try repo.createInitialCommit())

        XCTAssertEqual(try headCommitID(of: repo), head, "history was rewritten onto a new root commit")
    }

    /// The commit HEAD resolves to, as a hex id.
    private func headCommitID(of repo: Repository) throws -> String {
        var oid = git_oid()
        try gitCheck(git_reference_name_to_id(&oid, repo.pointer, "HEAD"))
        // `git_oid_tostr_s` answers a buffer it reuses, so copy before the next call.
        return String(cString: git_oid_tostr_s(&oid))
    }

    func testInitializedRepositoryHasAnUnbornHeadUntilItIsCommittedInto() throws {
        let repo = try Repository.initialize(atPath: tempDir.path)
        try configureIdentity(in: repo)

        XCTAssertTrue(repo.isHeadUnborn)
        XCTAssertTrue(try repo.createInitialCommit())
        XCTAssertFalse(repo.isHeadUnborn)
    }

    func testBranchExists() throws {
        let repo = try GitFixture.repository(at: tempDir.path)
        let head = try repo.headBranchName()
        XCTAssertTrue(try repo.branchExists(head))
        XCTAssertFalse(try repo.branchExists("no-such-branch"))
    }

    func testHeadBranchIsCheckedOut() throws {
        let repo = try GitFixture.repository(at: tempDir.path)
        let head = try repo.headBranchName()
        XCTAssertTrue(try repo.isBranchCheckedOut(head))
        XCTAssertFalse(try repo.isBranchCheckedOut("no-such-branch"))
    }

    func testCleanRepositoryIsClean() throws {
        let repo = try GitFixture.repository(at: tempDir.path)
        XCTAssertTrue(try repo.isClean())
    }

    func testUntrackedFileMakesRepositoryDirty() throws {
        let repo = try GitFixture.repository(at: tempDir.path)
        let extra = tempDir.appendingPathComponent("scratch.txt")
        try "x".write(to: extra, atomically: true, encoding: .utf8)

        XCTAssertFalse(try repo.isClean())
    }

    func testModifiedFileMakesRepositoryDirty() throws {
        let repo = try GitFixture.repository(at: tempDir.path)

        // Modify the committed file's content in the working tree.
        try "casper fixture edited\n".write(
            to: tempDir.appendingPathComponent("README.md"),
            atomically: true, encoding: .utf8)

        XCTAssertFalse(try repo.isClean())
    }

    func testDeletedFileMakesRepositoryDirty() throws {
        let repo = try GitFixture.repository(at: tempDir.path)

        // Delete the committed file in the working tree.
        try FileManager.default.removeItem(
            at: tempDir.appendingPathComponent("README.md"))

        XCTAssertFalse(try repo.isClean())
    }

    func testRemoteURL() throws {
        let repo = try GitFixture.repository(at: tempDir.path)

        XCTAssertNil(try repo.remoteURL(named: "origin"))

        var remote: OpaquePointer?
        try gitCheck(git_remote_create(
            &remote, repo.pointer, "origin", "https://github.com/acme/casper.git"))
        git_remote_free(remote)

        XCTAssertEqual(
            try repo.remoteURL(named: "origin"), "https://github.com/acme/casper.git")
    }
}
