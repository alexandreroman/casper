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
            repoPath: "/repo",
            worktreePath: "/repo/wt",
            branch: "feat-x",
            agentState: .running,
            todos: [Todo(content: "wire up", status: .inProgress)],
            pendingNotification: false,
            portBase: 40010,
            layout: layout
        )
        return Session(workspaces: [ws])
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
}
