import XCTest
@testable import CasperCore

final class AgentStateReducerTests: XCTestCase {
    private func makeWorkspace() -> Workspace {
        Workspace(
            name: "feat-x", worktreePath: "/r/w", branch: "feat-x",
            portBase: 40000, layout: .tabGroup(surfaces: [], activeIndex: 0)
        )
    }

    func testSessionStartSetsRunningAndClearsNotification() {
        var ws = makeWorkspace()
        ws.pendingNotification = true
        let effect = AgentStateReducer.apply(.sessionStart, to: &ws, focused: true)
        XCTAssertEqual(ws.agentState, .running)
        XCTAssertFalse(ws.pendingNotification)
        XCTAssertNil(effect)
    }

    func testTodoUpdateStoresTodosAndSetsRunningWhenInProgress() {
        var ws = makeWorkspace()
        let todos = [
            Todo(content: "a", status: .completed),
            Todo(content: "b", status: .inProgress),
        ]
        let effect = AgentStateReducer.apply(.todoUpdate(todos: todos), to: &ws, focused: true)
        XCTAssertEqual(ws.todos, todos)
        XCTAssertEqual(ws.agentState, .running)
        XCTAssertNil(effect)
    }

    func testNotificationWhenUnfocusedSetsWaitingAndNotifies() {
        var ws = makeWorkspace()
        let effect = AgentStateReducer.apply(.notification(message: "needs input"), to: &ws, focused: false)
        XCTAssertEqual(ws.agentState, .waiting)
        XCTAssertTrue(ws.pendingNotification)
        XCTAssertEqual(effect, .notify(title: "feat-x", body: "needs input"))
    }

    func testNotificationWhenFocusedDoesNotNotify() {
        var ws = makeWorkspace()
        let effect = AgentStateReducer.apply(.notification(message: "x"), to: &ws, focused: true)
        XCTAssertEqual(ws.agentState, .waiting)
        XCTAssertFalse(ws.pendingNotification)
        XCTAssertNil(effect)
    }

    func testStopWhenUnfocusedSetsDoneAndNotifies() {
        var ws = makeWorkspace()
        let effect = AgentStateReducer.apply(.stop, to: &ws, focused: false)
        XCTAssertEqual(ws.agentState, .done)
        XCTAssertTrue(ws.pendingNotification)
        XCTAssertEqual(effect, .notify(title: "feat-x", body: "Agent finished"))
    }

    func testTodoUpdateWithNoInProgressLeavesStateUnchanged() {
        var ws = makeWorkspace() // starts .idle
        let todos = [
            Todo(content: "a", status: .completed),
            Todo(content: "b", status: .pending),
        ]
        let effect = AgentStateReducer.apply(.todoUpdate(todos: todos), to: &ws, focused: true)
        XCTAssertEqual(ws.todos, todos)
        XCTAssertEqual(ws.agentState, .idle) // no in-progress item → state untouched
        XCTAssertNil(effect)
    }
}
