import AppKit
import CasperCore
import SwiftUI

/// The pinned agent-integration reminders, sitting between the scrolling workspace
/// list and the "Add Folder…" footer.
///
/// Non-modal by design: Casper detects an agent's integration and nudges, it never
/// repairs another tool's configuration (see the agent-integration policy). So these
/// rows stay quiet — advisory glyph, `.secondary` text, no destructive red — and each
/// one can be dismissed for good.
///
/// With nothing to say the view renders *nothing at all*: no divider, no padding, no
/// empty container. The footer then sits directly under the list, exactly as it does
/// for a user with no coding agent installed — which is most of the time.
struct AgentIntegrationReminderView: View {
    let model: AppModel

    var body: some View {
        if !model.agentIntegrationReminders.isEmpty {
            // The divider belongs to the reminders, not to the footer below: it only
            // exists to separate them from the workspace list, so it has to vanish
            // with them.
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.agentIntegrationReminders) { reminder in
                    AgentIntegrationReminderRow(model: model, reminder: reminder)
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// Longest installed-version string a row shows, ellipsis included.
    ///
    /// A version is whatever another tool wrote down — a Codex cache *directory
    /// name*, or a Claude registry field that is legitimately the literal
    /// `"unknown"` — so nothing guarantees it is short or even sane. Real ones are a
    /// handful of characters; past this the string stops identifying the install and
    /// starts eating the row's two lines.
    static let maxDisplayedVersionLength = 12

    /// What one line says, in the sidebar's own voice.
    ///
    /// Kept short on purpose: the sidebar is 220–400 pt wide and the row caps at two
    /// lines, so a longer sentence would be truncated rather than read. The outdated
    /// line still names the installed version, bounded by
    /// `maxDisplayedVersionLength`: it is the one detail that makes a nag someone
    /// believes is wrong diagnosable from a screenshot, and it matters most on the
    /// Codex path, whose install layout has never been checked against a real
    /// install.
    static func message(for reminder: AppModel.AgentIntegrationReminder) -> String {
        let name = reminder.agent.displayName
        switch reminder.kind {
        case .trustNotice:
            return "\(name) integration needs approval in /hooks"
        case .actionNeeded:
            switch reminder.status {
            case .outdated(let installed):
                guard let version = displayVersion(installed) else {
                    return "\(name) integration is outdated"
                }
                return "\(name) integration is outdated (\(version))"
            // Only `.missing` reaches here; `.notInstalled` and `.installed` never
            // produce an action-needed line, and are listed to keep this exhaustive.
            case .missing, .notInstalled, .installed:
                return "\(name) integration not installed"
            }
        }
    }

    /// The installed version as a row may show it, or nil when nothing printable is
    /// left — in which case the line drops the parenthesis rather than showing an
    /// empty one.
    ///
    /// Whitespace runs collapse to single spaces before the length cap applies: a
    /// version taken from a directory name can carry newlines, and one of those in
    /// the middle of the message would burn a whole row line on a hard break.
    static func displayVersion(_ installed: String) -> String? {
        let collapsed = installed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > maxDisplayedVersionLength else { return collapsed }
        return String(collapsed.prefix(maxDisplayedVersionLength - 1)) + "…"
    }

    /// The leading glyph. The two kinds must not look alike — one says "there is
    /// something for you to do", the other "this is set up, one step from active".
    static func symbolName(for kind: AppModel.AgentIntegrationReminder.Kind) -> String {
        switch kind {
        // Advisory rather than destructive: the triangle carries "worth your
        // attention" without the red an actual error would need.
        case .actionNeeded: return "exclamationmark.triangle"
        case .trustNotice: return "info.circle"
        }
    }
}

/// One reminder line: a wide button opening the integration guide, and a separate
/// dismiss button beside it.
///
/// The two are **siblings**, never nested. A dismiss control inside the row button
/// would inherit its hit area and every dismissal would also open a browser tab;
/// keeping them side by side in the `HStack` makes that impossible by construction
/// rather than by tuning `contentShape`.
private struct AgentIntegrationReminderRow: View {
    let model: AppModel
    let reminder: AppModel.AgentIntegrationReminder

    @State private var isHovered = false
    @State private var isDismissHovered = false

    var body: some View {
        HStack(spacing: 0) {
            Button {
                NSWorkspace.shared.open(reminder.documentationURL)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: AgentIntegrationReminderView.symbolName(for: reminder.kind))
                    Text(AgentIntegrationReminderView.message(for: reminder))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    // Claims the leftover width so the dismiss button is pushed to the
                    // trailing edge and the whole message area stays clickable.
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(SidebarActionButtonStyle(isHovered: isHovered, verticalPadding: 6))
            .onHover { isHovered = $0 }
            .help("Open the \(reminder.agent.displayName) integration guide")

            Button {
                model.dismissAgentReminder(reminder)
            } label: {
                Image(systemName: "xmark")
                    .imageScale(.small)
            }
            .buttonStyle(SidebarActionButtonStyle(
                isHovered: isDismissHovered, verticalPadding: 6, horizontalPadding: 8))
            .onHover { isDismissHovered = $0 }
            .help("Dismiss this reminder")
            .accessibilityLabel("Dismiss the \(reminder.agent.displayName) integration reminder")
        }
        .font(.footnote)
    }
}
