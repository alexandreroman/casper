import CasperCore
import CasperGhostty
import SwiftUI

/// Renders a workspace's `LayoutNode` recursively: splits as native
/// `HSplitView`/`VSplitView`, tab groups as a tab bar + a ZStack of surfaces.
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
        case .tabGroup(let surfaces, let activeIndex):
            TabGroupView(
                model: model, workspace: workspace,
                surfaces: surfaces, activeIndex: activeIndex)
        }
    }

    @ViewBuilder
    private func childViews(_ children: [LayoutNode]) -> some View {
        ForEach(Array(children.enumerated()), id: \.element.stableID) { _, child in
            LayoutNodeView(model: model, workspace: workspace, node: child)
        }
    }
}
