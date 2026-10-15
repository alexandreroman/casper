import XCTest
import CasperCore
@testable import CasperUI

/// Pins how a sidebar row turns a workspace's todos into its progress bar and
/// caption: the bar fills through the step in progress, while the green
/// "complete" look waits for every todo to be completed.
final class RowDisplayStateTests: XCTestCase {
    func testLastStepInProgressFillsTheBarWithoutCompletingIt() throws {
        let todos = try XCTUnwrap(ProgressSynthesis.todos(total: 3, current: 3, label: "Ship"))

        let state = RowDisplayState(workspace: makeWorkspace(todos: todos))

        XCTAssertTrue(state.showsProgress)
        XCTAssertEqual(state.progressFraction, 1.0, accuracy: 0.0001)
        XCTAssertFalse(state.isComplete)
        XCTAssertEqual(state.caption, "Ship")
    }

    func testFirstStepInProgressFillsOneThird() throws {
        let todos = try XCTUnwrap(ProgressSynthesis.todos(total: 3, current: 1, label: "Plan"))

        let state = RowDisplayState(workspace: makeWorkspace(todos: todos))

        XCTAssertTrue(state.showsProgress)
        XCTAssertEqual(state.progressFraction, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertFalse(state.isComplete)
    }

    func testEveryTodoCompletedFillsTheBarAndCompletesIt() throws {
        // `Todo` has no public initializer, so start from a synthesized list and
        // mark its last, in-progress step completed.
        var todos = try XCTUnwrap(ProgressSynthesis.todos(total: 3, current: 3, label: "Ship"))
        todos[2].status = .completed

        let state = RowDisplayState(workspace: makeWorkspace(todos: todos))

        XCTAssertTrue(state.showsProgress)
        XCTAssertEqual(state.progressFraction, 1.0, accuracy: 0.0001)
        XCTAssertTrue(state.isComplete)
        XCTAssertEqual(state.caption, "Done")
    }

    func testNoTodosShowsNoProgress() {
        let state = RowDisplayState(workspace: makeWorkspace(todos: []))

        XCTAssertFalse(state.showsProgress)
        XCTAssertEqual(state.progressFraction, 0)
        XCTAssertFalse(state.isComplete)
        XCTAssertNil(state.caption)
    }

    private func makeWorkspace(todos: [Todo]) -> Workspace {
        Workspace(
            name: "main", worktreePath: "/wt", branch: "main", todos: todos,
            portBase: 40000, layout: .leaf(Surface.terminal(cwd: "/wt")))
    }
}
