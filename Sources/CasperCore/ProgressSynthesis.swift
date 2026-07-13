/// Builds a `[Todo]` that realizes an explicit `current`/`total`/`label` progress
/// report. The app has no stored progress field — `Workspace.progress` and
/// `.currentTask` are derived from `todos` (see `Progress.swift`) — so an explicit
/// `casper progress set` must synthesize the todo list the sidebar reads back.
public enum ProgressSynthesis {
    public static func todos(total: Int, current: Int, label: String) -> [Todo]? {
        guard total >= 1, current >= 1, current <= total else { return nil }
        var todos: [Todo] = []
        todos.append(contentsOf: Array(repeating: Todo(content: "", status: .completed), count: current - 1))
        todos.append(Todo(content: label, status: .inProgress))
        todos.append(contentsOf: Array(repeating: Todo(content: "", status: .pending), count: total - current))
        return todos
    }
}
