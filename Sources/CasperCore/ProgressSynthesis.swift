/// Builds a `[Todo]` that realizes an explicit `current`/`total`/`label` progress
/// report. The app has no stored progress field — the sidebar derives everything it
/// shows from `Workspace.todos` — so an explicit `casper progress set` must
/// synthesize the todo list that read-back walks.
public enum ProgressSynthesis {
    /// Largest `total` a caller may request. `total` comes straight from
    /// untrusted CLI input and sizes the allocated array one-for-one, so it needs
    /// a ceiling: without one, `--total 100000000` allocates ~100M todos and
    /// `--total <Int.max>` traps inside `Array(repeating:count:)`. A thousand
    /// steps is already far past any progress bar a human reads.
    public static let maxSynthesizedTotal = 1_000

    public static func todos(total: Int, current: Int, label: String) -> [Todo]? {
        guard total >= 1, total <= maxSynthesizedTotal, current >= 1, current <= total else { return nil }
        var todos: [Todo] = []
        todos.append(contentsOf: Array(repeating: Todo(content: "", status: .completed), count: current - 1))
        todos.append(Todo(content: label, status: .inProgress))
        todos.append(contentsOf: Array(repeating: Todo(content: "", status: .pending), count: total - current))
        return todos
    }
}
