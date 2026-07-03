import CasperCore
import CasperGhostty
import SwiftUI

struct WorkspaceDetailView: View {
    @Bindable var model: AppModel
    let workspace: Workspace
    @Binding var columnVisibility: NavigationSplitViewVisibility

    /// Cached diff summary so it isn't recomputed on every render; refreshed when
    /// the selected workspace changes (see the `.task` below).
    @State private var diff: (insertions: Int, deletions: Int)?

    var body: some View {
        LayoutNodeView(model: model, workspace: workspace, node: workspace.layout)
            .toolbar {
                ToolbarItem(placement: .navigation) { leadingButtons }.flatToolbarItem()
                ToolbarItem(placement: .navigation) { title }.flatToolbarItem()
                if #available(macOS 26.0, *) {
                    ToolbarSpacer(.flexible)
                }
                ToolbarItem(placement: .primaryAction) { actions }.flatToolbarItem()
            }
            .task(id: model.selectedWorkspaceID) {
                diff = model.diffSummary(for: workspace)
            }
    }

    private var title: some View {
        HStack(spacing: 7) {
            Octicon(.gitBranch).foregroundStyle(.secondary)
            Text(workspace.branch.isEmpty ? workspace.name : workspace.branch)
                .fontWeight(.bold)
            Text(spaceName).foregroundStyle(.secondary)
        }
    }

    private var spaceName: String {
        model.space(for: workspace)?.name ?? workspace.name
    }

    private var actions: some View {
        HStack(spacing: 6) {
            if let diff {
                HStack(spacing: 6) {
                    Text("+\(diff.insertions)").foregroundStyle(.green)
                    Text("−\(diff.deletions)").foregroundStyle(.red)
                }
                .font(.callout.monospacedDigit())
            }
            Button {
                model.newTerminalInSelectedWorkspace()
            } label: {
                Octicon(.terminal)
            }
            .help("New terminal")
            Button {
                model.newBrowserInSelectedWorkspace()
            } label: {
                Octicon(.globe)
            }
            .help("New browser")
        }
    }

    private var leadingButtons: some View {
        HStack(spacing: 6) {
            Button {
                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
            } label: {
                Image(systemName: "sidebar.left")
            }
            .help("Toggle sidebar")
            Button {
                model.presentAddFolderPanel()
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .help("Add a Space")
        }
    }
}

private extension ToolbarContent {
    /// Removes the automatic macOS 26 "Liquid Glass" capsule background that
    /// wraps toolbar item content, so the title and actions render flat.
    @ToolbarContentBuilder
    func flatToolbarItem() -> some ToolbarContent {
        if #available(macOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
