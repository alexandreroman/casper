import CasperCore
import CasperGhostty
import SwiftUI

/// Renders a workspace's `LayoutNode` recursively: splits via
/// `SplitContainerView` (system `Divider()` separators, so all separators in the
/// app match), and each leaf as a single pane via `SurfaceHostView`.
struct LayoutNodeView: View {
    @Bindable var model: AppModel
    let workspace: Workspace
    let node: LayoutNode

    var body: some View {
        switch node {
        case .split(let orientation, let children, let ratios):
            SplitContainerView(
                model: model, workspace: workspace,
                orientation: orientation, children: children, ratios: ratios)
        case .leaf(let surface):
            SurfaceHostView(model: model, workspace: workspace, surface: surface)
        }
    }
}
