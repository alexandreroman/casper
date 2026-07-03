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
        VStack(spacing: 0) {
            Divider()
            LayoutNodeView(model: model, workspace: workspace, node: workspace.layout)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .inspector(isPresented: inspectorPresented) {
            InspectorPanel(model: model, workspace: workspace)
                // `ideal` seeds the INITIAL column width only; feeding the
                // per-workspace stored width restores it on a fresh launch.
                .inspectorColumnWidth(
                    min: InspectorState.minWidth,
                    ideal: workspace.inspector.width,
                    max: InspectorState.maxWidth)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) { title }
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.flexible)
            }
            ToolbarItem(placement: .primaryAction) { diffBadge }.flatToolbarItem()
            ToolbarItem(placement: .primaryAction) { inspectorToggle }
        }
        .task(id: model.selectedWorkspaceID) {
            diff = model.diffSummary(for: workspace)
        }
    }

    /// Bridges the workspace's persisted `inspector.collapsed` flag to the native
    /// inspector's `isPresented` binding (presented == not collapsed).
    private var inspectorPresented: Binding<Bool> {
        Binding(
            get: { !workspace.inspector.collapsed },
            set: { model.setInspectorCollapsed(!$0, for: workspace.id) }
        )
    }

    private var title: some View {
        HStack(spacing: 7) {
            Octicon(.gitBranch).foregroundStyle(.secondary)
            Text(workspace.branch.isEmpty ? workspace.name : workspace.branch)
                .fontWeight(.bold)
            Text(spaceName).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
    }

    private var spaceName: String {
        model.space(for: workspace)?.name ?? workspace.name
    }

    @ViewBuilder private var diffBadge: some View {
        if let diff, diff.insertions > 0 || diff.deletions > 0 {
            Button {
                model.setInspectorTab(.diff, for: workspace.id)
            } label: {
                HStack(spacing: 5) {
                    Text("+\(diff.insertions)").foregroundStyle(.green.opacity(0.9))
                    Text("−\(diff.deletions)").foregroundStyle(.red.opacity(0.9))
                }
                .font(.caption.monospacedDigit().bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.12), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Show diff")
        }
    }

    private var inspectorToggle: some View {
        Button {
            model.toggleInspectorCollapsed(for: workspace.id)
        } label: {
            Image(systemName: "sidebar.right")
        }
        .help("Toggle panel")
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
