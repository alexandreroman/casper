import CasperTestSupport
import Clibgit2
import Foundation
import XCTest
@testable import CasperGit

final class GitFixtureTests: XCTestCase {
    func testFixtureCreatesRepoWithOneCommit() throws {
        let dir = makeTemporaryDirectory(prefix: "casper-fixture")

        let repo = try GitFixture.repository(at: dir.path)

        // HEAD must now resolve (born branch).
        var head: OpaquePointer?
        XCTAssertEqual(git_repository_head(&head, repo.pointer), 0)
        git_reference_free(head)
    }
}
