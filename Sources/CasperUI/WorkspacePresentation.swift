import CasperCore

extension AgentState {
    /// Compact status glyph shown in a sidebar row.
    var badgeGlyph: String {
        switch self {
        case .running: return "●"
        case .waiting: return "◐"
        case .done: return "✓"
        case .error: return "✕"
        case .idle, .unknown: return "○"
        }
    }
}

extension Workspace {
    /// `"completed/total"`, or `nil` when the workspace has no todos.
    var progressLabel: String? {
        let p = progress
        return p.total == 0 ? nil : "\(p.completed)/\(p.total)"
    }
}
