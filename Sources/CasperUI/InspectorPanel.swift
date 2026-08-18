import AppKit
import CasperCore
import SwiftUI

/// The right-side inspector panel for a workspace: a top separator continuing
/// the workspace title bar's line, then full-bleed content with a vertical,
/// icon-only tab rail pinned to the panel's right edge.
/// The rail is hand-rolled from `Button`s rather than a native segmented
/// `Picker` — which lays its segments out horizontally and drops their icons on
/// macOS — so the tabs can stack vertically as bare SF Symbols.
/// The Browser view reuses `BrowserSurfaceView` on the workspace's dedicated
/// inspector surface; the Diff view reuses `DiffSurfaceView` for the working
/// tree vs HEAD.
///
/// The panel is ALWAYS mounted by `WorkspaceDetailView` (which reveals it by
/// animating a clip width so the rail never lags a transition). The chrome —
/// top separator, rail, `Divider` — therefore stays live at all times, while
/// the heavy `content` is gated on the inspector being expanded. On collapse
/// only the diff is genuinely torn down (its view is unmounted and its
/// `highlightTask` cancelled); the browser `WKWebView` survives on purpose —
/// its `BrowserCoordinator` is cached by `Surface.id` in `AppModel` and only
/// detached from the view hierarchy here, so the page and history persist.
struct InspectorPanel: View {
    let model: AppModel
    let workspace: Workspace

    /// Shared namespace so the single selected-tab pill can slide between the
    /// rail's buttons via `matchedGeometryEffect` when the selection changes.
    @Namespace private var tabSelection

    var body: some View {
        // The panel no longer owns its width: `WorkspaceDetailView`'s custom
        // resizable divider sets it via `.frame(width:)`, so the panel simply
        // fills whatever width it is given.
        VStack(spacing: 0) {
            // Spans the full panel width, including the rail, so the line
            // continues the workspace title bar's line uninterrupted.
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 2)
                .padding(.top, -1)
                .padding(.leading, -1)
            HStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                tabRail
            }
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

    /// The vertical tab rail along the panel's right edge: a narrow full-height
    /// strip holding the icon-only tab buttons, top-aligned. Its own background
    /// sets it apart from the content it sits next to.
    private var tabRail: some View {
        VStack(spacing: 2) {
            tabButton(.diff, title: "Diff", systemImage: "plusminus")
            tabButton(.browser, title: "Browser", systemImage: "globe")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        // Two calls: `frame` has no overload mixing a fixed width with a
        // flexible height.
        .frame(width: 34)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        // Animate the matched-geometry pill (and the icon colors) so the selected
        // indicator slides vertically between the buttons on selection change.
        .animation(.smooth(duration: 0.22), value: workspace.inspector.tab)
    }

    /// One button of `tabRail`: a plain, icon-only button that routes through
    /// `setInspectorTab` (which also keeps the panel expanded). The selected
    /// button is raised with a filled pill; the rest stay clear. The title is
    /// carried by the tooltip and the accessibility label instead of a visible
    /// text label.
    private func tabButton(_ tab: InspectorTab, title: String, systemImage: String) -> some View {
        let isSelected = workspace.inspector.tab == tab
        return Button {
            model.setInspectorTab(tab, for: workspace.id)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .frame(width: 26, height: 24)
                // A single pill exists only behind the selected button and is
                // matched across buttons, so it slides rather than cross-fades.
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color(nsColor: .controlColor))
                            .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                            .matchedGeometryEffect(id: "selectedTab", in: tabSelection, isSource: true)
                    }
                }
                // Make the whole padded pill clickable, not just the glyph:
                // `.plain` buttons hit-test the label's content shape by default.
                .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}
