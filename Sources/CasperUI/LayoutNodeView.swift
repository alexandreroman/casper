import CasperCore
import SwiftUI

/// Renders a workspace's `LayoutNode` recursively: splits via
/// `SplitContainerView` (whose splitters draw a 1pt `.separatorColor` line, so
/// all separators in the app match), and each leaf as a single pane via
/// `SurfaceHostView`.
///
/// Carries the workspace's **id** and layout rather than the `Workspace` value:
/// a workspace also holds the transient agent fields (state, todos, pending
/// notification, info Markdown), which change on every agent tick. Storing one
/// here would give this view — and every pane below it — a different value on
/// each tick, so SwiftUI could never prune the pane tree's bodies for a change
/// no pane renders.
struct LayoutNodeView: View {
    let model: AppModel
    let workspaceID: UUID
    let node: LayoutNode
    /// Whether the workspace holds more than one pane, which is what makes a pane
    /// draggable and a drop target. Resolved once for the whole tree by
    /// `WorkspaceDetailView`, since no node below the root can see the root layout.
    let canDragPanes: Bool
    /// Child-index path from the workspace's root layout to `node` (root = `[]`).
    /// Threaded so a split can persist its dragged ratios back to the model.
    var path: [Int] = []

    var body: some View {
        switch node {
        case .split(let orientation, let children, let ratios):
            SplitContainerView(
                model: model, workspaceID: workspaceID, canDragPanes: canDragPanes, path: path,
                orientation: orientation, children: children, ratios: ratios)
        case .leaf(let surface):
            SurfaceHostView(
                model: model, workspaceID: workspaceID, surface: surface, canDrag: canDragPanes)
        }
    }
}
