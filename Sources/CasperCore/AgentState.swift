import Foundation

public enum AgentEffect: Equatable, Sendable {
    case notify(title: String, body: String)
}

public enum AgentStateReducer {
    @discardableResult
    public static func apply(
        _ event: HookEvent,
        to workspace: inout Workspace,
        focused: Bool
    ) -> AgentEffect? {
        switch event {
        case .sessionStart:
            workspace.agentState = .running
            workspace.pendingNotification = false
            return nil

        case .todoUpdate(let todos):
            workspace.todos = todos
            if todos.contains(where: { $0.status == .inProgress }) {
                workspace.agentState = .running
            }
            return nil

        case .notification(let message):
            workspace.agentState = .waiting
            guard !focused else { return nil }
            workspace.pendingNotification = true
            return .notify(title: workspace.name, body: message)

        case .stop:
            workspace.agentState = .done
            guard !focused else { return nil }
            workspace.pendingNotification = true
            return .notify(title: workspace.name, body: "Agent finished")
        }
    }
}
