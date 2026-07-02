import XCTest
import CasperAgents
import CasperCore
@testable import CasperUI

@MainActor
final class AppModelTests: XCTestCase {
    private func makeStore() -> (SessionStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("casper-test-\(UUID().uuidString).json")
        return (SessionStore(fileURL: url), url)
    }

    func testStartsEmptyWhenSessionEmpty() {
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        XCTAssertTrue(model.isEmpty)
        XCTAssertNil(model.selectedWorkspaceID)
    }

    func testAddWorkspaceAppendsSelectsAndPersists() throws {
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        model.addWorkspace(folderURL: URL(fileURLWithPath: "/tmp/plain"), probe: { _ in nil })
        XCTAssertEqual(model.workspaces.count, 1)
        XCTAssertEqual(model.selectedWorkspaceID, model.workspaces[0].id)
        // Persisted synchronously.
        XCTAssertEqual(try store.load().workspaces.count, 1)
    }

    func testAddedWorkspacesGetDistinctPortBlocks() {
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        model.addWorkspace(folderURL: URL(fileURLWithPath: "/tmp/a"), probe: { _ in nil })
        model.addWorkspace(folderURL: URL(fileURLWithPath: "/tmp/b"), probe: { _ in nil })
        XCTAssertNotEqual(model.workspaces[0].portBase, model.workspaces[1].portBase)
    }

    func testRemoveDeletesEntryAndFixesSelection() throws {
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        model.addWorkspace(folderURL: URL(fileURLWithPath: "/tmp/a"), probe: { _ in nil })
        model.addWorkspace(folderURL: URL(fileURLWithPath: "/tmp/b"), probe: { _ in nil })
        let second = model.workspaces[1].id
        model.selectedWorkspaceID = second
        model.removeWorkspace(id: second)
        XCTAssertEqual(model.workspaces.count, 1)
        XCTAssertEqual(model.selectedWorkspaceID, model.workspaces[0].id)
        XCTAssertEqual(try store.load().workspaces.count, 1)
    }

    func testRestoresPersistedSessionAndSelectsFirst() {
        let existing = Session(workspaces: [
            Workspace(name: "a", repoPath: "/a", worktreePath: "/a", branch: "",
                      portBase: 40000, layout: .tabGroup(surfaces: [], activeIndex: 0)),
        ])
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store, session: existing)
        XCTAssertEqual(model.workspaces.count, 1)
        XCTAssertEqual(model.selectedWorkspaceID, existing.workspaces[0].id)
    }

    func testAddAfterRestoreDoesNotReuseRestoredPortBlock() {
        let existing = Session(workspaces: [
            Workspace(name: "a", repoPath: "/a", worktreePath: "/a", branch: "",
                      portBase: 40000, layout: .tabGroup(surfaces: [], activeIndex: 0)),
        ])
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store, session: existing)
        model.addWorkspace(folderURL: URL(fileURLWithPath: "/tmp/b"), probe: { _ in nil })
        XCTAssertEqual(model.workspaces.count, 2)
        XCTAssertNotEqual(model.workspaces[1].portBase, 40000)
    }

    private func todoWritePayload() -> Data {
        let json: [String: Any] = [
            "hook_event_name": "PostToolUse",
            "tool_name": "TodoWrite",
            "tool_input": ["todos": [["content": "task", "status": "in_progress"]]],
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    func testHookMessageUpdatesAddressedWorkspace() {
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        model.isWindowKey = { false }
        model.addWorkspace(folderURL: URL(fileURLWithPath: "/tmp/a"), probe: { _ in nil })
        let id = model.workspaces[0].id
        let msg = HookMessage(workspaceId: id, hookPayload: todoWritePayload())
        model.handleHookMessage(msg, now: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(model.workspaces[0].agentState, .running)
        XCTAssertEqual(model.workspaces[0].todos.first?.content, "task")
    }

    func testUnfocusedNotificationEventDeliversNotification() {
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        model.isWindowKey = { false }
        var delivered: [(String, String)] = []
        model.deliverNotification = { title, body in delivered.append((title, body)) }
        model.addWorkspace(folderURL: URL(fileURLWithPath: "/tmp/a"), probe: { _ in nil })
        let id = model.workspaces[0].id
        let payload = try! JSONSerialization.data(withJSONObject: [
            "hook_event_name": "Notification", "message": "needs input",
        ])
        model.handleHookMessage(HookMessage(workspaceId: id, hookPayload: payload),
                                now: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(model.workspaces[0].agentState, .waiting)
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.1, "needs input")
    }

    func testUnknownWorkspaceMessageIsIgnored() {
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        model.addWorkspace(folderURL: URL(fileURLWithPath: "/tmp/a"), probe: { _ in nil })
        let before = model.workspaces[0]
        let msg = HookMessage(workspaceId: UUID(), hookPayload: todoWritePayload())
        model.handleHookMessage(msg, now: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(model.workspaces[0], before)
    }

    func testHeartbeatMarksSilentWorkspaceUnknown() {
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        model.isWindowKey = { false }
        model.heartbeatTimeout = 30
        model.addWorkspace(folderURL: URL(fileURLWithPath: "/tmp/a"), probe: { _ in nil })
        let id = model.workspaces[0].id
        // Activity at t=1000 puts it in running.
        model.handleHookMessage(HookMessage(workspaceId: id, hookPayload: todoWritePayload()),
                                now: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(model.workspaces[0].agentState, .running)
        // 31s later it is stale.
        model.tickHeartbeat(now: Date(timeIntervalSince1970: 1031))
        XCTAssertEqual(model.workspaces[0].agentState, .unknown)
    }

    func testHeartbeatLeavesFreshWorkspaceUntouched() {
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        model.isWindowKey = { false }
        model.heartbeatTimeout = 30
        model.addWorkspace(folderURL: URL(fileURLWithPath: "/tmp/a"), probe: { _ in nil })
        let id = model.workspaces[0].id
        model.handleHookMessage(HookMessage(workspaceId: id, hookPayload: todoWritePayload()),
                                now: Date(timeIntervalSince1970: 1000))
        model.tickHeartbeat(now: Date(timeIntervalSince1970: 1010))
        XCTAssertEqual(model.workspaces[0].agentState, .running)
    }

    func testHeartbeatIgnoresWorkspaceWithNoActivity() {
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        model.addWorkspace(folderURL: URL(fileURLWithPath: "/tmp/a"), probe: { _ in nil })
        model.tickHeartbeat(now: Date(timeIntervalSince1970: 9999))
        XCTAssertEqual(model.workspaces[0].agentState, .idle)
    }

    func testHeartbeatAfterRemoveLeavesRemainingWorkspacesUnchanged() {
        let (store, _) = makeStore()
        let model = AppModel(sessionStore: store)
        model.isWindowKey = { false }
        model.heartbeatTimeout = 30
        model.addWorkspace(folderURL: URL(fileURLWithPath: "/tmp/a"), probe: { _ in nil })
        model.addWorkspace(folderURL: URL(fileURLWithPath: "/tmp/b"), probe: { _ in nil })
        let removedID = model.workspaces[0].id
        let remainingID = model.workspaces[1].id
        model.handleHookMessage(
            HookMessage(workspaceId: removedID, hookPayload: todoWritePayload()),
            now: Date(timeIntervalSince1970: 1000))
        model.handleHookMessage(
            HookMessage(workspaceId: remainingID, hookPayload: todoWritePayload()),
            now: Date(timeIntervalSince1970: 1000))
        model.removeWorkspace(id: removedID)
        // The stale activity entry for the removed workspace must not resurface
        // on a later tick and must not crash despite the workspace being gone.
        model.tickHeartbeat(now: Date(timeIntervalSince1970: 1010))
        XCTAssertEqual(model.workspaces.count, 1)
        XCTAssertEqual(model.workspaces[0].agentState, .running)
    }

    func testSessionRoundTripsThroughRealSessionStore() throws {
        let (store, url) = makeStore()
        let model = AppModel(sessionStore: store)
        model.addWorkspace(folderURL: URL(fileURLWithPath: "/tmp/roundtrip"), probe: { _ in nil })

        let reloadedStore = SessionStore(fileURL: url)
        let reloadedSession = try reloadedStore.load()
        let reloadedModel = AppModel(sessionStore: reloadedStore, session: reloadedSession)

        XCTAssertEqual(reloadedModel.workspaces.count, 1)
        XCTAssertEqual(reloadedModel.workspaces[0].name, model.workspaces[0].name)
        XCTAssertEqual(reloadedModel.workspaces[0].portBase, model.workspaces[0].portBase)
    }
}
