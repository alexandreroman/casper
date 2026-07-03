import XCTest
import CasperCore
@testable import CasperUI

final class WorkspaceFactoryTests: XCTestCase {
    func testMakeSpaceGitBacked() {
        let space = WorkspaceFactory.makeSpace(
            folderURL: URL(fileURLWithPath: "/tmp/repo"),
            probe: { _ in WorkspaceFactory.GitInfo(canonicalPath: "/tmp/repo", branch: "main") },
            portBase: 40000)
        XCTAssertTrue(space.isGitRepo)
        XCTAssertEqual(space.folderPath, "/tmp/repo")
        XCTAssertEqual(space.workspaces.count, 1)
        XCTAssertEqual(space.workspaces[0].kind, .primary)
        XCTAssertEqual(space.workspaces[0].branch, "main")
    }

    func testMakeSpaceNonGit() {
        let space = WorkspaceFactory.makeSpace(
            folderURL: URL(fileURLWithPath: "/tmp/plain"),
            probe: { _ in nil }, portBase: 40000)
        XCTAssertFalse(space.isGitRepo)
        XCTAssertEqual(space.workspaces[0].branch, "")
    }
}
