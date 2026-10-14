import CasperTestSupport
import Clibgit2
import Foundation
import XCTest
@testable import CasperGit

final class GitFixtureTests: XCTestCase {
    func testFixtureCreatesRepoWithOneCommit() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("casper-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let repo = try GitFixture.repository(at: dir.path)

        // HEAD must now resolve (born branch).
        var head: OpaquePointer?
        XCTAssertEqual(git_repository_head(&head, repo.pointer), 0)
        git_reference_free(head)
    }
}
