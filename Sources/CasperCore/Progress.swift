public extension Workspace {
    var progress: (completed: Int, total: Int) {
        let completed = todos.filter { $0.status == .completed }.count
        return (completed, todos.count)
    }

    var currentTask: String? {
        todos.first { $0.status == .inProgress }?.content
    }

    var progressFraction: Double {
        let (completed, total) = progress
        return total > 0 ? Double(completed) / Double(total) : 0
    }

    var isComplete: Bool {
        let (completed, total) = progress
        return total > 0 && completed == total
    }

    /// The Git branch to show for this workspace, falling back to the workspace
    /// name when there is no branch (e.g. a non-Git space).
    var branchLabel: String { branch.isEmpty ? name : branch }
}
