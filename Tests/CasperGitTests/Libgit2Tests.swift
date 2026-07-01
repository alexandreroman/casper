import XCTest
import Clibgit2
@testable import CasperGit

final class Libgit2Tests: XCTestCase {
    func testEnsureInitIsIdempotent() {
        Libgit2.ensureInit()
        Libgit2.ensureInit()  // must not crash or over-init
        XCTAssertTrue(true)
    }

    func testGitCheckThrowsOnNegativeCode() {
        // Force a known failure: open a non-existent repo.
        Libgit2.ensureInit()
        var repo: OpaquePointer?
        let code = git_repository_open(&repo, "/nonexistent/casper/repo")
        XCTAssertLessThan(code, 0)
        XCTAssertThrowsError(try gitCheck(code)) { error in
            guard let gitError = error as? GitError else {
                return XCTFail("expected GitError, got \(error)")
            }
            XCTAssertEqual(gitError.code, code)
            XCTAssertFalse(gitError.message.isEmpty)
        }
    }

    func testGitCheckReturnsCodeOnSuccess() throws {
        XCTAssertEqual(try gitCheck(0), 0)
    }
}
