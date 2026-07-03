import AppKit
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

    private static let defaultInspectorWidth: CGFloat = 360
    private static let minInspectorWidth: CGFloat = 240
    private static let maxInspectorWidth: CGFloat = 720

    /// User-chosen inspector width. Held in view `@State` so it survives the
    /// `if !collapsed` toggle within the same workspace view.
    @State private var inspectorWidth: CGFloat = WorkspaceDetailView.defaultInspectorWidth
    /// Width captured at the start of a drag, so the panel resizes relative to
    /// where it was when the drag began rather than accumulating per event.
    @State private var widthBeforeDrag: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                LayoutNodeView(model: model, workspace: workspace, node: workspace.layout)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !workspace.inspector.collapsed {
                    resizeDivider
                    InspectorPanel(model: model, workspace: workspace)
                        .frame(width: inspectorWidth)
                }
            }
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

    /// System separator with a transparent 10pt hit area straddling it so the
    /// user can drag to resize the inspector. Dragging left widens the panel.
    private var resizeDivider: some View {
        Divider()
            .overlay {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 10)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let base = widthBeforeDrag ?? inspectorWidth
                                if widthBeforeDrag == nil { widthBeforeDrag = base }
                                let proposed = base - value.translation.width
                                inspectorWidth = min(
                                    max(proposed, WorkspaceDetailView.minInspectorWidth),
                                    WorkspaceDetailView.maxInspectorWidth)
                            }
                            .onEnded { _ in widthBeforeDrag = nil }
                    )
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
                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
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
