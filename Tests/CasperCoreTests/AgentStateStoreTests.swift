import Foundation
import XCTest
@testable import CasperCore

final class AgentStateStoreTests: XCTestCase {
    private func makeWorkspace(name: String = "ws") -> Workspace {
        Workspace(
            name: name, worktreePath: "/wt", branch: "main",
            portBase: 40000,
            layout: .leaf(Surface(kind: .terminal(cwd: "/wt", command: nil))))
    }

    func testHandleSessionStartSetsRunning() {
        let ws = makeWorkspace()
        let store = AgentStateStore(workspaces: [ws])
        let effect = store.handle(.sessionStart, workspaceId: ws.id, focused: true)
        XCTAssertNil(effect)
        XCTAssertEqual(store.workspace(id: ws.id)?.agentState, .running)
    }

    func testHandleStopUnfocusedReturnsNotifyEffect() {
        let ws = makeWorkspace(name: "feature")
        let store = AgentStateStore(workspaces: [ws])
        let effect = store.handle(.stop, workspaceId: ws.id, focused: false)
        XCTAssertEqual(effect, .notify(title: "feature", body: "Agent finished"))
        XCTAssertEqual(store.workspace(id: ws.id)?.agentState, .done)
        XCTAssertEqual(store.workspace(id: ws.id)?.pendingNotification, true)
    }

    func testHandleTodoUpdateStoresTodos() {
        let ws = makeWorkspace()
        let store = AgentStateStore(workspaces: [ws])
        let todos = [Todo(content: "a", status: .inProgress)]
        store.handle(.todoUpdate(todos: todos), workspaceId: ws.id, focused: true)
        XCTAssertEqual(store.workspace(id: ws.id)?.todos, todos)
        XCTAssertEqual(store.workspace(id: ws.id)?.agentState, .running)
    }

    func testHandleUnknownWorkspaceIsNoOp() {
        let store = AgentStateStore(workspaces: [makeWorkspace()])
        let effect = store.handle(.stop, workspaceId: UUID(), focused: false)
        XCTAssertNil(effect)
    }

    func testOnChangeFiresWithMutatedWorkspace() {
        let ws = makeWorkspace()
        let store = AgentStateStore(workspaces: [ws])
        var changed: Workspace?
        store.onChange = { changed = $0 }
        store.handle(.sessionStart, workspaceId: ws.id, focused: true)
        XCTAssertEqual(changed?.agentState, .running)
    }

    func testMarkUnknownSetsUnknownState() {
        let ws = makeWorkspace()
        let store = AgentStateStore(workspaces: [ws])
        store.markUnknown(workspaceId: ws.id)
        XCTAssertEqual(store.workspace(id: ws.id)?.agentState, .unknown)
    }

    func testMarkErrorSetsErrorStateAndFiresOnChange() {
        let ws = makeWorkspace()
        let store = AgentStateStore(workspaces: [ws])
        var changed: Workspace?
        store.onChange = { changed = $0 }
        store.markError(workspaceId: ws.id)
        XCTAssertEqual(store.workspace(id: ws.id)?.agentState, .error)
        XCTAssertEqual(changed?.agentState, .error)
    }

    func testMarkUnknownForMissingWorkspaceIsNoOp() {
        let store = AgentStateStore(workspaces: [makeWorkspace()])
        var fired = false
        store.onChange = { _ in fired = true }
        store.markUnknown(workspaceId: UUID())
        XCTAssertFalse(fired)
    }

    func testMarkErrorForMissingWorkspaceIsNoOp() {
        let store = AgentStateStore(workspaces: [makeWorkspace()])
        var fired = false
        store.onChange = { _ in fired = true }
        store.markError(workspaceId: UUID())
        XCTAssertFalse(fired)
    }

    func testTodoUpdateWithEmptyArrayClearsPreviousTodos() {
        let ws = makeWorkspace()
        let store = AgentStateStore(workspaces: [ws])
        store.handle(
            .todoUpdate(todos: [Todo(content: "a", status: .inProgress)]),
            workspaceId: ws.id, focused: true)
        XCTAssertFalse(store.workspace(id: ws.id)?.todos.isEmpty ?? true)

        store.handle(.todoUpdate(todos: []), workspaceId: ws.id, focused: true)
        XCTAssertEqual(store.workspace(id: ws.id)?.todos, [])
    }
}
