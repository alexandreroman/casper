import CasperCore
import SwiftUI

struct WorkspaceRow: View {
    let workspace: Workspace

    var body: some View {
        HStack(spacing: 8) {
            Text(workspace.agentState.badgeGlyph)
                .foregroundStyle(color(for: workspace.agentState))
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name).lineLimit(1)
                HStack(spacing: 6) {
                    if !workspace.branch.isEmpty {
                        Text(workspace.branch).font(.caption).foregroundStyle(.secondary)
                    }
                    if let progress = workspace.progressLabel {
                        Text(progress).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let task = workspace.currentTask {
                    Text(task).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer()
            if workspace.pendingNotification {
                Circle().fill(.blue).frame(width: 7, height: 7)
            }
        }
    }

    private func color(for state: AgentState) -> Color {
        switch state {
        case .running: return .green
        case .waiting: return .yellow
        case .done: return .blue
        case .error: return .red
        case .idle, .unknown: return .secondary
        }
    }
}
