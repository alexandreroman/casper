import CasperCore
import SwiftUI

struct WorkspaceRow: View {
    let workspace: Workspace

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Octicon(.gitBranch)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 7) {
                Text(workspace.name).lineLimit(1)
                if workspace.progress.total > 0 {
                    ProgressBar(fraction: fraction, complete: isComplete)
                    if let task = taskLabel {
                        Text(task).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 6)
            NotificationBubble(on: workspace.pendingNotification)
                .padding(.top, 2)
        }
    }

    private var fraction: Double {
        let (completed, total) = workspace.progress
        return total > 0 ? Double(completed) / Double(total) : 0
    }

    private var isComplete: Bool {
        let (completed, total) = workspace.progress
        return total > 0 && completed == total
    }

    private var taskLabel: String? {
        workspace.currentTask ?? (isComplete ? "Done" : nil)
    }
}

/// A full-width thin progress bar: accent while running, green once complete.
private struct ProgressBar: View {
    let fraction: Double
    let complete: Bool

    var body: some View {
        GeometryReader { geo in
            Capsule().fill(.quaternary)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(complete ? Color.green : Color.accentColor)
                        .frame(width: geo.size.width * fraction)
                }
        }
        .frame(height: 4)
    }
}

/// Trailing notification indicator: a filled blue dot when pending, otherwise a
/// faint hollow ring so the row's trailing edge stays visually anchored.
private struct NotificationBubble: View {
    let on: Bool

    var body: some View {
        if on {
            Circle().fill(.blue).frame(width: 9, height: 9)
        } else {
            Circle().strokeBorder(.secondary.opacity(0.4), lineWidth: 1).frame(width: 9, height: 9)
        }
    }
}
