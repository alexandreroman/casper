import CasperCore
import SwiftUI

/// The right-side inspector panel for a workspace: a top separator continuing
/// the workspace title bar's line, then full-bleed content.
/// The panel carries no tab control of its own — which tab it shows is chosen
/// by the title bar's Diff and Browser chips (see `WorkspaceDetailView`), which
/// double as the panel's open/close toggle.
/// The Browser view reuses `BrowserSurfaceView` on the workspace's dedicated
/// inspector surface; the Diff view reuses `DiffSurfaceView` for the working
/// tree vs HEAD.
///
/// The panel is ALWAYS mounted by `WorkspaceDetailView` (which reveals it by
/// animating a clip width so nothing lags a transition). The top separator
/// therefore stays live at all times, while the heavy `content` is gated on the
/// inspector being expanded. On collapse only the diff is genuinely torn down
/// (its view is unmounted and its `highlightTask` cancelled); the browser
/// `WKWebView` survives on purpose — its `BrowserCoordinator` is cached by
/// `Surface.id` in `AppModel` and only detached from the view hierarchy here,
/// so the page and history persist.
struct InspectorPanel: View {
    let model: AppModel
    let workspace: Workspace

    var body: some View {
        // The panel no longer owns its width: `WorkspaceDetailView`'s custom
        // resizable divider sets it via `.frame(width:)`, so the panel simply
        // fills whatever width it is given.
        VStack(spacing: 0) {
            // Spans the full panel width, so the line continues the workspace
            // title bar's line uninterrupted. Twice the hairline, pulled up and
            // leading by one: the extra thickness is a deliberate bleed past the
            // panel's own top-leading corner, so the line meets the title bar's
            // rather than stopping a hairline short of it.
            Rectangle()
                .fill(SeparatorMetrics.fill)
                .frame(height: 2 * SeparatorMetrics.visibleWidth)
                .padding(.top, -SeparatorMetrics.visibleWidth)
                .padding(.leading, -SeparatorMetrics.visibleWidth)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var content: some View {
        // The panel is mounted even while collapsed (clipped to zero width), so
        // only mount the diff or the browser view when it is actually visible; an
        // empty filler keeps the collapsed panel inert. Collapsing unmounts the
        // diff, but the browser's cached `WKWebView` (keyed by `Surface.id`)
        // survives and is merely detached from the view hierarchy.
        if workspace.inspector.collapsed {
            Color.clear
        } else {
            switch workspace.inspector.tab {
            case .browser:
                BrowserSurfaceView(model: model, surface: workspace.inspector.browser)
            case .diff:
                DiffSurfaceView(model: model, workspace: workspace)
            }
        }
    }
}
