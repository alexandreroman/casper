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
}
