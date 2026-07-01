import Foundation

public extension Workspace {
    var progress: (completed: Int, total: Int) {
        let completed = todos.filter { $0.status == .completed }.count
        return (completed, todos.count)
    }

    var currentTask: String? {
        todos.first { $0.status == .inProgress }?.content
    }
}
