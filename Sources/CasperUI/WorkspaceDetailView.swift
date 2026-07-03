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

    private static let minInspectorWidth: CGFloat = 240
    private static let idealInspectorWidth: CGFloat = 360
    private static let maxInspectorWidth: CGFloat = 720

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            LayoutNodeView(model: model, workspace: workspace, node: workspace.layout)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .inspector(isPresented: inspectorPresented) {
            InspectorPanel(model: model, workspace: workspace)
                .inspectorColumnWidth(
                    min: Self.minInspectorWidth,
                    ideal: Self.idealInspectorWidth,
                    max: Self.maxInspectorWidth)
        }
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
    }

    private var spaceName: String {
        model.space(for: workspace)?.name ?? workspace.name
    }

    private var actions: some View {
        HStack(spacing: 8) {
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
            Button {
                model.toggleInspectorCollapsed(for: workspace.id)
            } label: {
                Image(systemName: "sidebar.right")
            }
            .tint(workspace.inspector.collapsed ? nil : .accentColor)
            .help("Toggle panel")
        }
    }

    private var leadingButtons: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.22)) {
                    columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                }
            } label: {
                Image(systemName: "sidebar.left")
            }
            .help("Toggle sidebar")
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
