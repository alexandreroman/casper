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
}
