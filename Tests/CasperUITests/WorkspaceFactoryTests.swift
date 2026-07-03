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
        XCTAssertEqual(space.name, "repo")
        XCTAssertEqual(space.folderPath, "/tmp/repo")
        XCTAssertEqual(space.workspaces.count, 1)
        XCTAssertEqual(space.workspaces[0].kind, .primary)
        XCTAssertEqual(space.workspaces[0].branch, "main")
        // The primary workspace roots at the probe's canonical path, not just
        // the folder that was opened.
        XCTAssertEqual(space.workspaces[0].worktreePath, "/tmp/repo")
        guard case .tabGroup(let surfaces, _) = space.workspaces[0].layout,
              case .terminal(let cwd, _) = surfaces[0].kind else {
            return XCTFail("expected a single terminal surface")
        }
        XCTAssertEqual(surfaces.count, 1)
        XCTAssertEqual(cwd, "/tmp/repo")
    }

    func testMakeSpaceNonGit() {
        let space = WorkspaceFactory.makeSpace(
            folderURL: URL(fileURLWithPath: "/tmp/plain"),
            probe: { _ in nil }, portBase: 40000)
        XCTAssertFalse(space.isGitRepo)
        XCTAssertEqual(space.name, "plain")
        XCTAssertEqual(space.workspaces.count, 1)
        XCTAssertEqual(space.workspaces[0].branch, "")
        // Non-Git folders are degenerate: the workspace roots at the opened
        // folder itself, with a terminal cwd to match.
        XCTAssertEqual(space.workspaces[0].worktreePath, "/tmp/plain")
        guard case .tabGroup(let surfaces, _) = space.workspaces[0].layout,
              case .terminal(let cwd, _) = surfaces[0].kind else {
            return XCTFail("expected a single terminal surface")
        }
        XCTAssertEqual(surfaces.count, 1)
        XCTAssertEqual(cwd, "/tmp/plain")
    }
}
