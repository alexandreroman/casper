import XCTest
import CasperCore
@testable import CasperUI

final class WorkspaceFactoryTests: XCTestCase {
    func testMakeSpaceGitBacked() {
        let space = WorkspaceFactory.makeSpace(
            folderURL: URL(fileURLWithPath: "/tmp/repo"),
            probe: { _ in WorkspaceFactory.GitInfo(canonicalPath: "/tmp/repo", branch: "main", remoteURL: nil) },
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

    func testMakeSpaceDerivesNameFromRemote() {
        let space = WorkspaceFactory.makeSpace(
            folderURL: URL(fileURLWithPath: "/tmp/checkout"),
            probe: { _ in WorkspaceFactory.GitInfo(
                canonicalPath: "/tmp/checkout", branch: "main",
                remoteURL: "https://github.com/acme/casper.git") },
            portBase: 40000)
        XCTAssertEqual(space.name, "casper")
    }

    func testMakeLinkedWorkspace() {
        let ws = WorkspaceFactory.makeLinkedWorkspace(
            name: "feat-x", worktreePath: "/r/.casper/worktrees/feat-x",
            branch: "feat-x", baseBranch: "main", portBase: 40010)
        XCTAssertEqual(ws.kind, .linked)
        XCTAssertEqual(ws.baseBranch, "main")
        XCTAssertEqual(ws.worktreePath, "/r/.casper/worktrees/feat-x")
        guard case .tabGroup(let surfaces, _) = ws.layout,
              case .terminal(let cwd, _) = surfaces.first?.kind else {
            return XCTFail("expected one terminal")
        }
        XCTAssertEqual(cwd, "/r/.casper/worktrees/feat-x")
    }
}
