import CasperCore
import CasperGhostty
import SwiftUI

struct WorkspaceDetailView: View {
    @Bindable var model: AppModel
    let workspace: Workspace

    /// Cached diff summary so it isn't recomputed on every render; refreshed when
    /// the selected workspace changes (see the `.task` below).
    @State private var diff: (insertions: Int, deletions: Int)?

    /// Live inspector width, seeded per-workspace on appear (the detail view has
    /// a per-workspace `.id`, so this resets on every workspace switch) and
    /// persisted on drag-end. Held locally so the divider drag never mutates
    /// observed model state mid-layout.
    @State private var inspectorWidth: Double?

    /// Keep at least this much room for the detail area when clamping the
    /// inspector's maximum width.
    private static let minDetailWidth: Double = 320

    /// Stable coordinate space for the inspector divider drag, anchored to the
    /// full-width detail container so the pointer's absolute location is read
    /// against a fixed origin (the divider itself moves as the panel resizes).
    private static let inspectorDragSpace = "inspectorDrag"

    var body: some View {
        GeometryReader { proxy in
            let range = inspectorRange(container: proxy.size.width)
            let width = (inspectorWidth ?? workspace.inspector.width)
                .clamped(to: range)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    LayoutNodeView(model: model, workspace: workspace, node: workspace.layout)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !workspace.inspector.collapsed {
                    inspectorDivider(total: proxy.size.width, range: range)
                    InspectorPanel(model: model, workspace: workspace)
                        .frame(width: width)
                        .transition(.move(edge: .trailing))
                }
            }
            .coordinateSpace(.named(Self.inspectorDragSpace))
            .animation(.easeInOut(duration: 0.18), value: workspace.inspector.collapsed)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) { title }
            ToolbarItem(placement: .navigation) { diffBadge }.flatToolbarItem()
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.flexible)
            }
            ToolbarItem(placement: .primaryAction) { inspectorToggle }
        }
        .task(id: model.selectedWorkspaceID) {
            diff = model.diffSummary(for: workspace)
        }
        .onAppear {
            if inspectorWidth == nil { inspectorWidth = workspace.inspector.width }
        }
    }

    /// Allowed inspector-width range for the given container width: never below
    /// `InspectorState.minWidth`, never above `InspectorState.maxWidth`, and
    /// always leaving at least `minDetailWidth` for the detail area.
    private func inspectorRange(container: Double) -> ClosedRange<Double> {
        let upper = max(InspectorState.minWidth,
                        min(InspectorState.maxWidth, container - Self.minDetailWidth))
        return InspectorState.minWidth...upper
    }

    /// A self-drawn vertical divider (mirrors `SplitContainerView`'s splitter: a
    /// 7pt transparent grab strip whose `contentShape` limits hit-testing, plus a
    /// 1pt separator line, carrying the column-resize pointer). Dragging it
    /// resizes the inspector; the model is persisted only on drag-end.
    private func inspectorDivider(total: Double, range: ClosedRange<Double>) -> some View {
        ZStack {
            Color.clear
                .frame(width: 7)
                .contentShape(Rectangle())
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
        }
        .frame(maxHeight: .infinity)
        .pointerStyle(.columnResize)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.inspectorDragSpace))
                .onChanged { value in
                    // Track the pointer's ABSOLUTE x in the stable container space:
                    // the inspector's left edge sits at value.location.x, so its
                    // width is the space remaining to the right. Using the absolute
                    // location (not accumulated translation) keeps the divider
                    // locked to the pointer even as the panel — and this divider —
                    // shift during the drag, eliminating the resize lag.
                    inspectorWidth = (total - value.location.x).clamped(to: range)
                }
                .onEnded { _ in
                    if let width = inspectorWidth {
                        model.setInspectorWidth(width, for: workspace.id)
                    }
                })
    }

    private var title: some View {
        HStack(spacing: 7) {
            Octicon(.gitBranch).foregroundStyle(.secondary)
            Text(workspace.branchLabel)
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
                    Text("+\(diff.insertions)").foregroundStyle(DiffLineStyle.insertionTint.opacity(0.9))
                    Text("−\(diff.deletions)").foregroundStyle(DiffLineStyle.deletionTint.opacity(0.9))
                }
                .font(.body.monospacedDigit().bold())
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

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
