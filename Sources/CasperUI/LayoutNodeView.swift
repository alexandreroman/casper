import CasperCore
import CasperGhostty
import SwiftUI

/// Renders a workspace's `LayoutNode` recursively: splits as native
/// `HSplitView`/`VSplitView` (thin dividers, no per-pane chrome), and each leaf
/// as a single pane via `SurfaceHostView`.
struct LayoutNodeView: View {
    @Bindable var model: AppModel
    let workspace: Workspace
    let node: LayoutNode

    var body: some View {
        switch node {
        case .split(let orientation, let children, _):
            if orientation == .horizontal {
                HSplitView { childViews(children) }
            } else {
                VSplitView { childViews(children) }
            }
        case .leaf(let surface):
            SurfaceHostView(model: model, workspace: workspace, surface: surface)
        }
    }

    @ViewBuilder
    private func childViews(_ children: [LayoutNode]) -> some View {
        // Keyed by position, a purely structural concern: surface identity anchors
        // on `Surface.id` alone, and `AppModel.surfaceViews` (keyed by that id)
        // preserves each PTY across restructuring regardless of this ForEach key.
        ForEach(Array(children.enumerated()), id: \.offset) { _, child in
            LayoutNodeView(model: model, workspace: workspace, node: child)
        }
    }
}
