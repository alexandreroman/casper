import CasperCore
import CasperGhostty
import SwiftUI

struct WorkspaceDetailView: View {
    @Bindable var model: AppModel
    let workspace: Workspace

    /// Cached diff summary so it isn't recomputed on every render; refreshed when
    /// the selected workspace changes (see the `.task` below).
    @State private var diff: (insertions: Int, deletions: Int)?

    var body: some View {
        LayoutNodeView(model: model, workspace: workspace, node: workspace.layout)
            .toolbar {
                ToolbarItem(placement: .principal) { title }
                ToolbarItemGroup(placement: .primaryAction) { actions }
            }
            .task(id: model.selectedWorkspaceID) {
                diff = model.diffSummary(for: workspace)
            }
    }

    private var title: some View {
        HStack(spacing: 7) {
            BranchIcon().foregroundStyle(.secondary)
            Text(workspace.branch.isEmpty ? workspace.name : workspace.branch)
            Text(workspace.worktreePath)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actions: some View {
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
            Image(systemName: "terminal")
        }
        .help("New terminal")
        Button {
            model.newBrowserInSelectedWorkspace()
        } label: {
            Image(systemName: "globe")
        }
        .help("New browser")
    }
}
