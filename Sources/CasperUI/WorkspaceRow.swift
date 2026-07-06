import CasperCore
import SwiftUI

/// A workspace row: a leading Git/folder glyph, the branch label with optional
/// agent progress, and a trailing status cluster (an agent-state icon followed
/// by the notification bubble). Draws its own selection pill so the accent stays
/// visible even when the sidebar is not first responder.
struct WorkspaceRow: View {
    let workspace: Workspace
    let isSelected: Bool
    let isGitRepo: Bool

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Octicon(isGitRepo ? .gitBranch : .fileDirectory)
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
                Text(workspace.branchLabel)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                Spacer(minLength: 6)
                AgentStatusIcon(state: workspace.agentState, isSelected: isSelected)
                NotificationBubble(on: workspace.pendingNotification, isSelected: isSelected)
                    .frame(width: 20)
            }
            if workspace.progress.total > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressBar(
                        fraction: workspace.progressFraction,
                        complete: workspace.isComplete,
                        isSelected: isSelected)
                    if let task = taskLabel {
                        Text(task)
                            .font(.caption)
                            .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                            .lineLimit(1)
                    }
                }
                // Align under the branch label: leading icon (16) + HStack spacing (8).
                .padding(.leading, 24)
            }
        }
        // Indent the content by the header's chevron slot (16) + HStack spacing (8)
        // so the leading Octicon lines up under the Space name, not the chevron.
        // Applied inside the pill, so selection still spans the full row width.
        .padding(.leading, 24)
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor
                      : (isHovered ? Color.primary.opacity(0.06) : Color.clear))
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var taskLabel: String? {
        workspace.currentTask ?? (workspace.isComplete ? "Done" : nil)
    }
}

/// A full-width thin progress bar: accent while running, green once complete.
/// Selection-aware so it stays legible on the accent selection background.
private struct ProgressBar: View {
    let fraction: Double
    let complete: Bool
    let isSelected: Bool

    var body: some View {
        GeometryReader { geo in
            Capsule().fill(trackStyle)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(fillColor)
                        .frame(width: geo.size.width * fraction)
                }
        }
        .frame(height: 4)
    }

    private var trackStyle: AnyShapeStyle {
        isSelected ? AnyShapeStyle(Color.white.opacity(0.25)) : AnyShapeStyle(.quaternary)
    }

    private var fillColor: Color {
        if complete {
            return isSelected ? Color.green.opacity(0.9) : Color.green
        }
        return isSelected ? Color.white : Color.accentColor
    }
}

/// Trailing notification indicator: a filled dot when pending, otherwise hidden.
/// The call site reserves the trailing space so the row's edge stays anchored even
/// when nothing renders. Selection-aware so it reads on the accent selection background.
private struct NotificationBubble: View {
    let on: Bool
    let isSelected: Bool

    var body: some View {
        if on {
            Circle()
                .fill(isSelected ? Color.white : Color.blue)
                .frame(width: 9, height: 9)
        } else {
            EmptyView()
        }
    }
}

/// Trailing agent-status indicator: an SF Symbol reflecting the live `AgentState`.
/// `working` spins continuously; the `idle`/`unknown` states render nothing yet
/// still reserve a fixed-width slot so the notification bubble never shifts as the
/// state changes. Selection-aware so the glyphs read on the accent selection pill.
private struct AgentStatusIcon: View {
    let state: AgentState
    let isSelected: Bool

    var body: some View {
        Group {
            switch state {
            case .working:
                SpinningIcon(isSelected: isSelected)
            case .blocked:
                icon("exclamationmark.circle.fill", color: .orange)
            case .done:
                icon("checkmark.circle.fill", color: .green)
            case .error:
                icon("xmark.octagon.fill", color: .red)
            case .idle, .unknown:
                Color.clear
            }
        }
        .frame(width: 16)
    }

    private func icon(_ symbol: String, color: Color) -> some View {
        Image(systemName: symbol)
            .imageScale(.medium)
            .foregroundStyle(isSelected ? Color.white : color)
    }
}

/// The `working` glyph: a circular-arrows SF Symbol in continuous clockwise
/// rotation. The spin starts when the view appears — i.e. when the agent enters
/// the working state — and stops when it leaves, since the view is then torn down
/// and replaced by a different (non-animated) state glyph.
private struct SpinningIcon: View {
    let isSelected: Bool
    @State private var spin = false

    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .imageScale(.medium)
            .foregroundStyle(isSelected ? Color.white : Color.accentColor)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = true }
    }
}
