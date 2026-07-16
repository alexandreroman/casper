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
