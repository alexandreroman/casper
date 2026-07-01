import Foundation

public enum HookEvent: Equatable, Sendable {
    case sessionStart
    case stop
    case notification(message: String)
    case todoUpdate(todos: [Todo])
}

public enum HookParseError: Error, Equatable {
    case invalidJSON
    case missingField(String)
    case unsupportedEvent(String)
}

public enum HookEventParser {
    public static func parse(_ data: Data) throws -> HookEvent {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw HookParseError.invalidJSON
        }
        guard let name = obj["hook_event_name"] as? String else {
            throw HookParseError.missingField("hook_event_name")
        }

        switch name {
        case "SessionStart":
            return .sessionStart
        case "Stop":
            return .stop
        case "Notification":
            let message = obj["message"] as? String ?? ""
            return .notification(message: message)
        case "PostToolUse":
            let tool = obj["tool_name"] as? String ?? "?"
            guard tool == "TodoWrite" else {
                throw HookParseError.unsupportedEvent("PostToolUse:\(tool)")
            }
            let toolInput = obj["tool_input"] as? [String: Any] ?? [:]
            let rawTodos = toolInput["todos"] as? [[String: Any]] ?? []
            let todos = rawTodos.map { item in
                let content = item["content"] as? String ?? ""
                let statusRaw = item["status"] as? String ?? "pending"
                return Todo(content: content, status: TodoStatus(rawValue: statusRaw) ?? .pending)
            }
            return .todoUpdate(todos: todos)
        default:
            throw HookParseError.unsupportedEvent(name)
        }
    }
}
