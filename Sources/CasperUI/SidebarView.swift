import CasperCore
import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.spaces) { space in
                        SpaceHeaderView(model: model, space: space)
                            .contextMenu {
                                Button("Remove space", role: .destructive) {
                                    model.removeSpace(id: space.id)
                                }
                            }
                        if !space.isCollapsed {
                            ForEach(space.workspaces) { workspace in
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
            isGitRepo: space.isGitRepo
        )
        .onTapGesture { model.selectWorkspace(workspace.id) }
        .contextMenu {
            if workspace.kind == .linked {
                Button("Remove workspace", role: .destructive) {
                    model.removeWorkspace(id: workspace.id)
                }
            }
        }
    }
}

/// The pinned "Add folder…" button below the scrolling list, always reachable
/// (unlike the empty-state affordance) and never scrolling away.
private struct AddFolderFooter: View {
    let onAdd: () -> Void

    var body: some View {
        Button(action: onAdd) {
            HStack(spacing: 7) {
                Image(systemName: "plus")
                Text("Add folder…")
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }
}
