import XCTest
@testable import CasperCore

final class ProgressTests: XCTestCase {
    private func workspace(todos: [Todo]) -> Workspace {
        Workspace(
            name: "w", worktreePath: "/r/w", branch: "b",
            todos: todos, portBase: 40000,
            layout: .leaf(Surface(kind: .terminal(cwd: "/r/w", command: nil)))
        )
    }

    func testProgressCountsCompletedOverTotal() {
        let ws = workspace(todos: [
            Todo(content: "a", status: .completed),
            Todo(content: "b", status: .completed),
            Todo(content: "c", status: .inProgress),
            Todo(content: "d", status: .pending),
        ])
        XCTAssertEqual(ws.progress.completed, 2)
        XCTAssertEqual(ws.progress.total, 4)
    }

    func testCurrentTaskIsTheInProgressItem() {
        let ws = workspace(todos: [
            Todo(content: "a", status: .completed),
            Todo(content: "wiring", status: .inProgress),
        ])
        XCTAssertEqual(ws.currentTask, "wiring")
    }

    func testCurrentTaskNilWhenNoneInProgress() {
        let ws = workspace(todos: [Todo(content: "a", status: .completed)])
        XCTAssertNil(ws.currentTask)
    }
}
