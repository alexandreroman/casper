public extension Workspace {
    var progress: (completed: Int, total: Int) {
        // `count(where:)` rather than `filter { }.count`: the intermediate array
        // was allocated and thrown away on every read, and the sidebar reads this
        // for every workspace row on every model change.
        (completed: todos.count { $0.status == .completed }, total: todos.count)
    }

    var currentTask: String? {
        todos.first { $0.status == .inProgress }?.content
    }

    var progressFraction: Double {
        guard !todos.isEmpty else { return 0 }
        return Double(todos.count { $0.status == .completed }) / Double(todos.count)
    }

    /// Every todo completed, and at least one todo. `allSatisfy` stops at the first
    /// unfinished item instead of counting the whole list.
    var isComplete: Bool {
        !todos.isEmpty && todos.allSatisfy { $0.status == .completed }
    }

    /// The Git branch to show for this workspace, falling back to the workspace
    /// name when there is no branch (e.g. a non-Git space).
    var branchLabel: String { branch.isEmpty ? name : branch }
}
