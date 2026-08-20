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
        // The edge-trim can re-expose a forbidden `.lock` suffix, so per-component
        // normalization and the trim must iterate to a fixpoint, not run once.
        XCTAssertEqual(GitBranchName.sanitize("foo.lock"), "foo")
        XCTAssertEqual(GitBranchName.sanitize("foo.lock."), "foo")
        XCTAssertEqual(GitBranchName.sanitize("foo.lock-"), "foo")
        XCTAssertEqual(GitBranchName.sanitize("foo-.lock"), "foo")
        XCTAssertEqual(GitBranchName.sanitize("a.lock-.lock"), "a")
    }

    func testSanitizeSquashesOnlyRunsOfTheSameSeparator() {
        XCTAssertEqual(GitBranchName.sanitize("a---b"), "a-b")
        XCTAssertEqual(GitBranchName.sanitize("a----....b"), "a-.b")
        // Alternating separators are not a run: each one survives.
        XCTAssertEqual(GitBranchName.sanitize("a.-.b"), "a.-.b")
        XCTAssertEqual(GitBranchName.sanitize("a-.-b"), "a-.-b")
        // Slashes are separators for the per-component rules but are never squashed
        // as a run; empty components are dropped instead.
        XCTAssertEqual(GitBranchName.sanitize("a//b"), "a/b")
    }
}
