import XCTest
import Clibgit2
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
        XCTAssertFalse(info.isLocked)
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

    func testValidateWorktree() throws {
        let repo = try GitFixture.repository(at: repoDir.path)
        let wtPath = root.appendingPathComponent("feature").path
        _ = try repo.addWorktree(name: "feature", atPath: wtPath, basedOn: nil)
        XCTAssertTrue(try repo.isWorktreeValid(name: "feature"))
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

    func testValidateReturnsFalseForBrokenWorktree() throws {
        let repo = try GitFixture.repository(at: repoDir.path)
        let wtPath = root.appendingPathComponent("feature").path
        _ = try repo.addWorktree(name: "feature", atPath: wtPath, basedOn: nil)

        // Remove the working-tree directory out from under the worktree.
        try FileManager.default.removeItem(atPath: wtPath)

        XCTAssertFalse(try repo.isWorktreeValid(name: "feature"))
    }

    func testAddWorktreeRollsBackBranchWhenAddFails() throws {
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
    }

    func testPruneRemovesWorktree() throws {
        let repo = try GitFixture.repository(at: repoDir.path)
        let wtPath = root.appendingPathComponent("feature").path
        _ = try repo.addWorktree(name: "feature", atPath: wtPath, basedOn: nil)

        try repo.pruneWorktree(name: "feature")

        XCTAssertEqual(try repo.worktreeNames(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: wtPath))
    }
}
