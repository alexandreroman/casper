import XCTest
import CasperCore
@testable import CasperUI

final class WorkspaceFactoryTests: XCTestCase {
    func testGitFolderPopulatesRepoPathAndBranch() {
        let folder = URL(fileURLWithPath: "/tmp/repo/sub")
        let probe: (URL) -> WorkspaceFactory.RepoInfo? = { _ in
            WorkspaceFactory.RepoInfo(repoPath: "/tmp/repo", branch: "main")
        }
        let ws = WorkspaceFactory.makeWorkspace(folderURL: folder, probe: probe, portBase: 40000)
        XCTAssertEqual(ws.name, "sub")
        XCTAssertEqual(ws.repoPath, "/tmp/repo")
        XCTAssertEqual(ws.worktreePath, "/tmp/repo/sub")
        XCTAssertEqual(ws.branch, "main")
        XCTAssertEqual(ws.portBase, 40000)
        guard case .tabGroup(let surfaces, let active) = ws.layout else {
            return XCTFail("expected a tabGroup layout")
        }
        XCTAssertEqual(active, 0)
        XCTAssertEqual(surfaces.count, 1)
        guard case .terminal(let cwd, let command) = surfaces[0].kind else {
            return XCTFail("expected a terminal surface")
        }
        XCTAssertEqual(cwd, "/tmp/repo/sub")
        XCTAssertNil(command)
    }

    func testNonGitFolderUsesFolderAsRepoPathWithEmptyBranch() {
        let folder = URL(fileURLWithPath: "/tmp/plain")
        let ws = WorkspaceFactory.makeWorkspace(folderURL: folder, probe: { _ in nil }, portBase: 40010)
        XCTAssertEqual(ws.repoPath, "/tmp/plain")
        XCTAssertEqual(ws.worktreePath, "/tmp/plain")
        XCTAssertEqual(ws.branch, "")
        XCTAssertEqual(ws.name, "plain")
    }
}
