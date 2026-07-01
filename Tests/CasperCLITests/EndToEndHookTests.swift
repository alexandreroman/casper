import Foundation
import XCTest
@testable import CasperCLI
import CasperAgents
import CasperCore

final class EndToEndHookTests: XCTestCase {
    func testStopHookDrivesAgentStateToDone() throws {
        let socketPath = "/tmp/casper-e2e-\(UUID().uuidString.prefix(8)).sock"

        let workspace = Workspace(
            name: "e2e", repoPath: "/repo", worktreePath: "/wt", branch: "main",
            portBase: 40000, layout: .tabGroup(surfaces: [], activeIndex: 0))
        let store = AgentStateStore(workspaces: [workspace])

        // Surface env, exactly as a terminal surface would receive it.
        let env = ClaudeCodeAdapter.surfaceEnvironment(
            socketPath: socketPath, workspaceId: workspace.id, portBase: 40000)

        let done = XCTestExpectation(description: "state reached .done")
        let server = HookSocketServer(socketPath: socketPath)
        server.onMessage = { message in
            guard let event = try? HookEventParser.parse(message.hookPayload)
            else { return }
            store.handle(event, workspaceId: message.workspaceId, focused: true)
            if store.workspace(id: workspace.id)?.agentState == .done {
                done.fulfill()
            }
        }
        try server.start()
        defer { server.stop() }

        // The "fake agent": a Stop hook payload built through the CLI path.
        let stdin = Data(#"{"hook_event_name":"Stop"}"#.utf8)
        let message = try XCTUnwrap(
            HooksFeedCommand.makeMessage(stdin: stdin, environment: env))
        try HookSocketClient.send(message, toSocketAt: socketPath)

        wait(for: [done], timeout: 5)
        XCTAssertEqual(store.workspace(id: workspace.id)?.agentState, .done)
    }
}
