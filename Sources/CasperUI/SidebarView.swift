import CasperCore
import SwiftUI

struct SidebarView: View {
    let model: AppModel

    var body: some View {
        // Resolve the display order once per body pass: each Space's `orderedWorkspaces`
        // is a fresh sort, and the rows and the `Cmd+N` hints both need it. Deriving the
        // shortcut numbers from this very list — through the model's own numbering rule —
        // is what keeps the hints and `selectWorkspace(atShortcutNumber:)` in agreement.
        let ordered = model.spacesWithVisibleWorkspaces()
        let shortcutNumbers = AppModel.shortcutNumbers(for: ordered)
        return VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(ordered, id: \.space.id) { space, workspaces in
                        SpaceHeaderView(model: model, space: space)
                            .contextMenu {
                                Button("Remove Space", role: .destructive) {
                                    model.removeSpace(id: space.id)
                                }
                            }
                        ForEach(workspaces) { workspace in
                            row(for: workspace, in: space, shortcutNumber: shortcutNumbers[workspace.id])
                        }
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, 10)
            }
            AgentIntegrationReminderView(model: model)
            Divider()
            AddFolderFooter(onAdd: { model.presentAddFolderPanel() })
        }
        .navigationTitle("Casper")
    }

    /// A workspace row. Routes selection through `selectWorkspace` (not a plain
    /// binding) so picking a workspace also moves keyboard focus to its top-left
    /// terminal.
    private func row(for workspace: Workspace, in space: Space, shortcutNumber: Int?) -> some View {
        WorkspaceRow(
            workspace: workspace,
            isSelected: workspace.id == model.selectedWorkspaceID,
            isGitRepo: space.isGitRepo,
            shortcutNumber: shortcutNumber,
            showShortcutHints: model.showWorkspaceShortcutHints
        )
        .onTapGesture { model.selectWorkspace(workspace.id) }
        // Load this row's `.casper.json` commands here rather than from the menu
        // below, so building the menu stays a pure cache read.
        .onAppear { model.prewarmNamedCommands(for: workspace.id) }
        .contextMenu { contextMenu(for: workspace) }
    }

    /// The row's action menu: the shared `WorkspaceMenuItem` groups — the same
    /// description the File and Edit menus render — plus the sidebar-only "Run
    /// Script" submenu, which sits beside "Open in Finder" above the first separator.
    @ViewBuilder
    private func contextMenu(for workspace: Workspace) -> some View {
        let isLinked = workspace.kind == .linked
        let groups = WorkspaceMenuItem.groups(model: model, workspaceID: workspace.id) { command in
            switch command {
            case .openInFinder, .copyWorkspacePath, .copyBranchName: return true
            case .mergeAndClose: return workspace.canMerge
            case .delete: return isLinked
            }
        }
        MenuGroups(groups: groups, itemID: \.title) { item in
            Button(role: item.isDestructive ? .destructive : nil, action: item.action) {
                Label(item.title, systemImage: item.systemImage)
            }
            .disabled(!item.isEnabled)
        } groupSuffix: { index in
            if index == 0 { runScriptMenu(for: workspace) }
        }
    }

    /// The "Run Script" submenu, present only while the workspace's `.casper.json`
    /// defines at least one named command.
    @ViewBuilder
    private func runScriptMenu(for workspace: Workspace) -> some View {
        let commands = model.namedCommands(for: workspace.id)
        if !commands.isEmpty {
            Menu {
                ForEach(commands, id: \.name) { command in
                    Button(command.displayName) {
                        model.runScript(command.name, for: workspace.id)
                    }
                }
            } label: {
                Label("Run Script", systemImage: "play")
            }
        }
    }
}

/// The pinned "Add Folder…" button below the scrolling list, always reachable
/// (unlike the empty-state affordance) and never scrolling away.
private struct AddFolderFooter: View {
    let onAdd: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onAdd) {
            HStack(spacing: 7) {
                Image(systemName: "plus")
                Text("Add Folder…")
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(SidebarActionButtonStyle(isHovered: isHovered))
        .onHover { isHovered = $0 }
    }
}

/// Borderless-looking style that layers a hover highlight over a deeper neutral
/// pressed state (a stronger grey fill in the same hue family as hover) so a
/// sidebar-footer click reads unmistakably through color — `.borderless` alone
/// never surfaces `configuration.isPressed`.
///
/// Shared by the "Add Folder…" footer and the agent-integration reminder rows
/// above it, which is what keeps the two reading as one family of affordances;
/// the paddings default to the footer's and the denser reminder rows override them.
struct SidebarActionButtonStyle: ButtonStyle {
    let isHovered: Bool
    var verticalPadding: CGFloat = 8
    var horizontalPadding: CGFloat = 14

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foregroundColor(isPressed: configuration.isPressed))
            .padding(.vertical, verticalPadding)
            .padding(.horizontal, horizontalPadding)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(fillColor(isPressed: configuration.isPressed))
            )
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private func fillColor(isPressed: Bool) -> Color {
        if isPressed {
            return Color.primary.opacity(0.12)
        }
        if isHovered {
            return Color.primary.opacity(0.06)
        }
        return Color.clear
    }

    private func foregroundColor(isPressed: Bool) -> Color {
        return (isPressed || isHovered) ? .primary : .secondary
    }
}
