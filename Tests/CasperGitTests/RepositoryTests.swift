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

    func testDiscoverFromSubdirectory() throws {
        _ = try Repository.initialize(atPath: tempDir.path)
        let sub = tempDir.appendingPathComponent("a/b/c")
        try FileManager.default.createDirectory(
            at: sub, withIntermediateDirectories: true)
        let repo = try Repository.discover(startingAt: sub.path)
        XCTAssertEqual(
            URL(fileURLWithPath: repo.workdirPath!).standardizedFileURL.path,
            tempDir.standardizedFileURL.path)
    }

    func testHeadBranchNameAfterFixture() throws {
        let repo = try GitFixture.repository(at: tempDir.path)
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

    func testCleanRepositoryHasNoStatusEntries() throws {
        let repo = try GitFixture.repository(at: tempDir.path)
        XCTAssertTrue(try repo.isClean())
        XCTAssertEqual(try repo.status(), [])
    }

    func testUntrackedFileMakesRepositoryDirty() throws {
        let repo = try GitFixture.repository(at: tempDir.path)
        let extra = tempDir.appendingPathComponent("scratch.txt")
        try "x".write(to: extra, atomically: true, encoding: .utf8)

        XCTAssertFalse(try repo.isClean())
        let status = try repo.status()
        XCTAssertEqual(status.count, 1)
        XCTAssertEqual(status.first?.path, "scratch.txt")
        XCTAssertTrue(status.first?.isUntracked ?? false)
    }

    func testStagedModificationIsReportedAsModified() throws {
        let repo = try GitFixture.repository(at: tempDir.path)
        let readme = tempDir.appendingPathComponent("README.md")
        try "casper fixture changed\n".write(
            to: readme, atomically: true, encoding: .utf8)

        // Stage the modification via the index.
        var index: OpaquePointer?
        try gitCheck(git_repository_index(&index, repo.pointer))
        defer { git_index_free(index) }
        try gitCheck(git_index_add_bypath(index, "README.md"))
        try gitCheck(git_index_write(index))

        XCTAssertFalse(try repo.isClean())
        let entry = try repo.status().first { $0.path == "README.md" }
        XCTAssertEqual(entry?.isModified, true)
    }

    func testDeletedFileIsReportedAndKeepsRepositoryDirty() throws {
        let repo = try GitFixture.repository(at: tempDir.path)

        // Delete the committed file in the working tree.
        try FileManager.default.removeItem(
            at: tempDir.appendingPathComponent("README.md"))

        XCTAssertFalse(try repo.isClean())
        let entry = try repo.status().first { $0.path == "README.md" }
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.isDeleted, true)
    }
}
