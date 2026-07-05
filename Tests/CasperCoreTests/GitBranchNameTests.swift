import XCTest
@testable import CasperCore

final class GitBranchNameTests: XCTestCase {
    func testSanitize() {
        XCTAssertEqual(GitBranchName.sanitize("My Feature"), "my-feature")
        XCTAssertEqual(GitBranchName.sanitize("feat/AB C"), "feat/ab-c")
        XCTAssertEqual(GitBranchName.sanitize("a~b:c?d*e"), "a-b-c-d-e")
        XCTAssertEqual(GitBranchName.sanitize("  --hello--  "), "hello")
        XCTAssertNil(GitBranchName.sanitize(""))
        XCTAssertNil(GitBranchName.sanitize("   "))
        XCTAssertNil(GitBranchName.sanitize("@"))
    }

    func testSanitizeProducesValidRefNames() {
        // `..` must be collapsed fully, not by a single non-overlapping pass.
        XCTAssertEqual(GitBranchName.sanitize("a...b"), "a.b")
        // ASCII control characters (here U+0001) are stripped, never passed through.
        XCTAssertEqual(GitBranchName.sanitize("foo\u{01}bar"), "foo-bar")
        // The `@{` sequence Git forbids is broken.
        let atBrace = GitBranchName.sanitize("foo@{1}")
        XCTAssertNotNil(atBrace)
        XCTAssertFalse(atBrace?.contains("@{") ?? true)
        // `.lock` is stripped repeatedly, so no suffix survives.
        XCTAssertEqual(GitBranchName.sanitize("foo.lock.lock"), "foo")
        // Per-component rules apply to each slash-separated component, not just
        // the whole-string edges.
        XCTAssertEqual(GitBranchName.sanitize("a.lock/b"), "a/b")
        XCTAssertEqual(GitBranchName.sanitize("foo/.bar"), "foo/bar")
    }
}
