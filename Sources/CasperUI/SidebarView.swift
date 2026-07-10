import CasperCore
import SwiftUI

struct SidebarView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.spaces) { space in
                        SpaceHeaderView(model: model, space: space)
                            .contextMenu {
                                Button("Remove Space", role: .destructive) {
                                    model.removeSpace(id: space.id)
                                }
                            }
                        if !space.isCollapsed {
                            ForEach(space.orderedWorkspaces) { workspace in
                                row(for: workspace, in: space)
                            }
                        }
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, 10)
            }
            Divider()
            AddFolderFooter(onAdd: { model.presentAddFolderPanel() })
        }
        .navigationTitle("Casper")
    }

    /// A workspace row. Routes selection through `selectWorkspace` (not a plain
    /// binding) so picking a workspace also moves keyboard focus to its top-left
    /// terminal.
    private func row(for workspace: Workspace, in space: Space) -> some View {
        WorkspaceRow(
            workspace: workspace,
            isSelected: workspace.id == model.selectedWorkspaceID,
            isGitRepo: space.isGitRepo,
            shortcutNumber: model.workspaceShortcutNumbers[workspace.id],
            showShortcutHints: model.showWorkspaceShortcutHints
        )
        .onTapGesture { model.selectWorkspace(workspace.id) }
        .contextMenu {
            let isLinked = workspace.kind == .linked
            let canMerge = isLinked && !(workspace.baseBranch?.isEmpty ?? true)
            Button {
                model.copyWorkspacePath(id: workspace.id)
            } label: {
                Label("Copy Workspace Path", systemImage: "doc.on.doc")
            }
            Button {
                model.copyBranchName(id: workspace.id)
            } label: {
                Label("Copy Branch Name", systemImage: "doc.on.doc")
            }
            Divider()
            Button {
                model.presentCloseWorkspaceConfirmation(id: workspace.id)
            } label: {
                Label("Merge and Close Workspace…", systemImage: "arrow.triangle.merge")
            }
            .disabled(!canMerge)
            Divider()
            Button(role: .destructive) {
                model.presentDeleteWorkspaceConfirmation(id: workspace.id)
            } label: {
                Label("Delete Workspace…", systemImage: "trash")
            }
            .disabled(!isLinked)
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
        .buttonStyle(AddFolderButtonStyle(isHovered: isHovered))
        .onHover { isHovered = $0 }
    }
}

/// Borderless-looking style that layers a hover highlight over a deeper neutral
/// pressed state (a stronger grey fill in the same hue family as hover) so the
/// "Add Folder…" click reads unmistakably through color — `.borderless` alone
/// never surfaces `configuration.isPressed`.
private struct AddFolderButtonStyle: ButtonStyle {
    let isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foregroundColor(isPressed: configuration.isPressed))
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
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
