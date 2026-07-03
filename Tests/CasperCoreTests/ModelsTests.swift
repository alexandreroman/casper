import Foundation
import XCTest
@testable import CasperCore

final class ModelsTests: XCTestCase {
    private func sampleSession() -> Session {
        let term = Surface(kind: .terminal(cwd: "/repo/wt", command: nil))
        let browser = Surface(kind: .browser(url: URL(string: "http://localhost:40000")!))
        let diff = Surface(kind: .diff(againstHead: true))
        let layout = LayoutNode.split(
            orientation: .horizontal,
            children: [
                .tabGroup(surfaces: [term, browser], activeIndex: 0),
                .tabGroup(surfaces: [diff], activeIndex: 0),
            ],
            ratios: [0.6, 0.4]
        )
        let ws = Workspace(
            name: "feat-x",
            worktreePath: "/repo/wt",
            branch: "feat-x",
            agentState: .running,
            todos: [Todo(content: "wire up", status: .inProgress)],
            pendingNotification: false,
            portBase: 40010,
            layout: layout
        )
        let space = Space(
            name: "repo", folderPath: "/repo", isGitRepo: true, workspaces: [ws])
        return Session(spaces: [space])
    }

    func testSessionCodableRoundTrip() throws {
        let original = sampleSession()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Session.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testTodoStatusRawValuesMatchClaudeCode() {
        XCTAssertEqual(TodoStatus.pending.rawValue, "pending")
        XCTAssertEqual(TodoStatus.inProgress.rawValue, "in_progress")
        XCTAssertEqual(TodoStatus.completed.rawValue, "completed")
    }

    func testSpaceSessionRoundTrip() throws {
        let primary = Workspace(
            name: "app", worktreePath: "/r", branch: "main",
            portBase: 40000, layout: .tabGroup(surfaces: [], activeIndex: 0),
            kind: .primary)
        let linked = Workspace(
            name: "feat", worktreePath: "/r/.casper/worktrees/feat", branch: "feat",
            portBase: 40010, layout: .tabGroup(surfaces: [], activeIndex: 0),
            kind: .linked, baseBranch: "main")
        let space = Space(
            name: "app", folderPath: "/r", isGitRepo: true,
            workspaces: [primary, linked])
        let session = Session(spaces: [space])
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(Session.self, from: data)
        XCTAssertEqual(decoded, session)
        XCTAssertEqual(decoded.spaces.first?.workspaces.first?.kind, .primary)
        XCTAssertEqual(decoded.spaces.first?.workspaces.last?.baseBranch, "main")
    }

    func testWorkspaceKindRawValues() {
        XCTAssertEqual(WorkspaceKind.primary.rawValue, "primary")
        XCTAssertEqual(WorkspaceKind.linked.rawValue, "linked")
    }
}
