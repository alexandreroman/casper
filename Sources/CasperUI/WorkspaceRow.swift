import CasperCore
import SwiftUI

/// A workspace row: a leading agent-state icon sitting under the Space header's
/// chevron column, then the Git/folder glyph (aligned under the Space name) and
/// the branch label with optional agent progress, and a trailing notification
/// bubble (or, while Cmd is held, a `⌘N` shortcut hint) — see
/// `WorkspaceShortcutHint`. The caption line beneath shows a pending
/// notification message when one exists, falling back to the progress task
/// label otherwise. Draws its own selection pill so the accent stays visible
/// even when the sidebar is not first responder.
struct WorkspaceRow: View {
    let workspace: Workspace
    let isSelected: Bool
    let isGitRepo: Bool
    let shortcutNumber: Int?
    let showShortcutHints: Bool

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Derived once per body pass: a single walk over `todos` yields the counts,
        // the caption and the completion flag that the layout, the progress bar and
        // the `.animation(value:)` below all need. The sidebar re-renders every row
        // on any agent-state or progress tick, so the walk stays a single pass.
        let state = RowDisplayState(workspace: workspace)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                AgentStatusIcon(state: workspace.agentState, isSelected: isSelected)
                Octicon(isGitRepo ? .gitBranch : .fileDirectory)
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
                Text(workspace.branchLabel)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                Spacer(minLength: 6)
                Group {
                    if showShortcutHints, let shortcutNumber {
                        WorkspaceShortcutHint(number: shortcutNumber, isSelected: isSelected)
                            .transition(.opacity)
                    } else {
                        NotificationBubble(on: workspace.pendingNotification, isSelected: isSelected)
                            .transition(.opacity)
                    }
                }
                .frame(width: 20)
                .animation(.easeInOut(duration: 0.15), value: showShortcutHints)
            }
            if state.showsProgress || state.caption != nil {
                VStack(alignment: .leading, spacing: 6) {
                    if state.showsProgress {
                        ProgressBar(
                            fraction: state.progressFraction,
                            complete: state.isComplete,
                            isSelected: isSelected)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    if let caption = state.caption {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                            .lineLimit(1)
                            .contentTransition(.opacity)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                // Align under the branch label: status slot (16) + spacing (8) +
                // Octicon (16) + spacing (8).
                .padding(.leading, 48)
            }
        }
        // No extra leading indent: the row's content edge already matches the
        // header's content edge (both inset by pill 8 + outer 6). The leading
        // status slot (16) lines up under the header chevron, and the HStack's
        // 16 + 8 spacing lands the Octicon under the Space name — the exact
        // position it held before the status icon existed.
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
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: state)
    }
}

/// Everything a row renders and animates on, derived from a workspace in a single
/// pass over its todos. `Equatable` so it can drive `.animation(value:)` directly.
private struct RowDisplayState: Equatable {
    let agentState: AgentState
    let showsProgress: Bool
    let progressFraction: Double
    let isComplete: Bool
    /// The caption line under the branch label. A pending notification message
    /// takes priority over the progress task label — it's the more urgent
    /// signal — and stays shown until the notification clears (the workspace
    /// becomes focused, per `AppModel.clearNotificationForFocusedWorkspace`).
    /// Falls back to the progress task label so existing progress captions are
    /// unaffected once there is no pending message.
    let caption: String?

    init(workspace: Workspace) {
        var completed = 0
        var currentTask: String?
        for todo in workspace.todos {
            switch todo.status {
            case .completed: completed += 1
            case .inProgress: if currentTask == nil { currentTask = todo.content }
            case .pending: break
            }
        }
        let total = workspace.todos.count
        let isComplete = total > 0 && completed == total

        agentState = workspace.agentState
        showsProgress = total > 0
        progressFraction = total > 0 ? Double(completed) / Double(total) : 0
        self.isComplete = isComplete
        caption = workspace.pendingNotificationMessage ?? currentTask ?? (isComplete ? "Done" : nil)
    }
}

/// A full-width thin progress bar: accent while running, green once complete.
/// Selection-aware so it stays legible on the accent selection background.
private struct ProgressBar: View {
    let fraction: Double
    let complete: Bool
    let isSelected: Bool

    var body: some View {
        Capsule().fill(trackStyle)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(fillColor)
                    // Proportional fill without a per-row GeometryReader layout
                    // pass: scale a full-width capsule from its leading edge.
                    // Clamp to [0, 1] so an out-of-range fraction can't over- or
                    // under-draw.
                    .scaleEffect(x: max(0, min(1, fraction)), y: 1, anchor: .leading)
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

/// The `Cmd+N` hint shown in the notification bubble's slot while Cmd is held
/// past the reveal delay (see `WorkspaceShortcutKeyMonitor`). Selection-aware,
/// matching every other trailing/leading glyph in this row.
private struct WorkspaceShortcutHint: View {
    let number: Int
    let isSelected: Bool

    var body: some View {
        Text("⌘\(number)")
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(isSelected ? Color.white : Color.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

/// Trailing notification indicator: a filled dot when pending, otherwise hidden.
/// The call site reserves the trailing space so the row's edge stays anchored even
/// when nothing renders. Selection-aware so it reads on the accent selection background.
/// While pending, the dot pulses continuously (a breathing fade-and-scale) to draw the
/// eye, unless reduce-motion is on.
private struct NotificationBubble: View {
    let on: Bool
    let isSelected: Bool
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if on {
            let breathing: Animation? =
                reduceMotion ? nil : .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
            Circle()
                .fill(isSelected ? Color.white : Color.blue)
                .frame(width: 9, height: 9)
                .opacity(pulse ? 0.5 : 1.0)
                .scaleEffect(pulse ? 1.3 : 1.0)
                .animation(breathing, value: pulse)
                .onAppear { pulse = true }
        } else {
            EmptyView()
        }
    }
}

/// Leading agent-status indicator, occupying the chevron column under the Space
/// header: an SF Symbol reflecting the live `AgentState`. The icons are
/// monochrome — the symbol *shape* carries the distinction, not color — and are
/// tinted like the sibling Git glyph so the two leading columns read as one.
/// `working` spins continuously; the `idle`/`unknown` states render nothing yet
/// still reserve a fixed-width slot so the trailing Octicon column stays aligned
/// across rows as the state changes. Selection-aware so the glyphs read on the
/// accent selection pill.
private struct AgentStatusIcon: View {
    let state: AgentState
    let isSelected: Bool

    var body: some View {
        Group {
            switch state {
            case .working:
                SpinningIcon(isSelected: isSelected)
                    .transition(.opacity)
            case .blocked:
                icon("exclamationmark.circle")
                    .transition(.opacity)
            case .done:
                icon("checkmark.circle")
                    .transition(.opacity)
            case .error:
                icon("xmark.octagon")
                    .transition(.opacity)
            case .idle, .unknown:
                Color.clear
                    .transition(.opacity)
            }
        }
        .frame(width: 16)
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .imageScale(.medium)
            .foregroundStyle(isSelected ? Color.white : Color.secondary)
    }
}

/// The `working` glyph: a circular-arrows SF Symbol in continuous clockwise
/// rotation. The spin runs while the view exists — i.e. while the agent is in the
/// working state — and stops when it leaves, since the view is then torn down and
/// replaced by a different (non-animated) state glyph. Respects reduce-motion.
private struct SpinningIcon: View {
    let isSelected: Bool
    @State private var spin = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .imageScale(.medium)
            .foregroundStyle(isSelected ? Color.white : Color.secondary)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(reduceMotion ? nil : .linear(duration: 1).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = true }
    }
}
