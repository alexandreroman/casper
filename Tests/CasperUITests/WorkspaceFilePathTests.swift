import XCTest
@testable import CasperUI

/// The helper is pure and lexical — it does no filesystem access — so a
/// non-existent worktree like `/wt` yields deterministic results.
final class WorkspaceFilePathTests: XCTestCase {
    func testResolveRelativePathInsideWorktree() {
        XCTAssertEqual(
            WorkspaceFilePath.resolve("Sources/Foo.swift", inWorktree: "/wt"),
            "/wt/Sources/Foo.swift")
    }

    func testResolveAbsolutePathInsideWorktree() {
        XCTAssertEqual(
            WorkspaceFilePath.resolve("/wt/Sources/Foo.swift", inWorktree: "/wt"),
            "/wt/Sources/Foo.swift")
    }

    func testResolveRejectsRelativeEscape() {
        XCTAssertNil(WorkspaceFilePath.resolve("../etc/passwd", inWorktree: "/wt"))
    }

    func testResolveRejectsAbsoluteOutside() {
        XCTAssertNil(WorkspaceFilePath.resolve("/etc/passwd", inWorktree: "/wt"))
    }

    func testResolveAllowsInBoundsDotDot() {
        XCTAssertEqual(
            WorkspaceFilePath.resolve("a/../b.txt", inWorktree: "/wt"),
            "/wt/b.txt")
    }

    func testRelativeStripsWorktreePrefix() {
        XCTAssertEqual(
            WorkspaceFilePath.relative("/wt/Sources/Foo.swift", toWorktree: "/wt"),
            "Sources/Foo.swift")
    }
}
