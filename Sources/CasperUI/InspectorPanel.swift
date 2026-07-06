import AppKit
import CasperCore
import SwiftUI

/// The right-side inspector panel for a workspace: a top separator continuing
/// the workspace title bar's line, then a custom Diff | Browser segmented
/// selector centred at the top of the panel, over full-bleed content below.
/// The selector is hand-rolled from `Button`s (not a native segmented `Picker`,
/// which drops the segment icons on macOS) so each tab shows both its SF Symbol
/// and its text label.
/// The Browser view reuses `BrowserSurfaceView` on the workspace's dedicated
/// inspector surface; the Diff view reuses `DiffSurfaceView` for the working
/// tree vs HEAD.
///
/// The panel is ALWAYS mounted by `WorkspaceDetailView` (which reveals it by
/// animating a clip width so the selector never lags a transition). The chrome
/// — top separator, segmented selector, `Divider` — therefore stays live at all
/// times, but the heavy `content` (the diff computation and the browser
/// `WKWebView`) is gated on the inspector being expanded so those resources are
/// torn down while it is collapsed.
struct InspectorPanel: View {
    let model: AppModel
    let workspace: Workspace

    /// Shared namespace so the single selected-tab pill can slide between
    /// segments via `matchedGeometryEffect` when the selection changes.
    @Namespace private var tabSelection

    var body: some View {
        // The panel no longer owns its width: `WorkspaceDetailView`'s custom
        // resizable divider sets it via `.frame(width:)`, so the panel simply
        // fills whatever width it is given.
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 2)
                .padding(.top, -1)
                .padding(.leading, 1)
            tabSelector
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var content: some View {
        // The panel is mounted even while collapsed (clipped to zero width), so
        // only spin up the diff or the browser `WKWebView` when it is actually
        // visible; an empty filler keeps the collapsed panel inert.
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

    /// A custom segmented control that hugs its content and stays centred. Unlike
    /// a native `.segmented` `Picker`, it keeps each segment's SF Symbol next to
    /// its label. The whole group sits on a subtle rounded track.
    private var tabSelector: some View {
        HStack(spacing: 0) {
            tabSegment(.diff, title: "Diff", systemImage: "plusminus")
            tabSegment(.browser, title: "Browser", systemImage: "globe")
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5)))
        .fixedSize()
        // Animate the matched-geometry pill (and the label colors) so the
        // selected indicator slides between segments on selection change.
        .animation(.smooth(duration: 0.22), value: workspace.inspector.tab)
    }

    /// One segment of `tabSelector`: a plain button that routes through
    /// `setInspectorTab` (which also keeps the panel expanded). The selected
    /// segment is raised with a filled background; the rest stay clear.
    private func tabSegment(_ tab: InspectorTab, title: String, systemImage: String) -> some View {
        let isSelected = workspace.inspector.tab == tab
        return Button {
            model.setInspectorTab(tab, for: workspace.id)
        } label: {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                // A single pill exists only behind the selected segment and is
                // matched across segments, so it slides rather than cross-fades.
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color(nsColor: .controlColor))
                            .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                            .matchedGeometryEffect(id: "selectedTab", in: tabSelection, isSource: true)
                    }
                }
                // Make the whole padded pill clickable, not just the glyphs:
                // `.plain` buttons hit-test the label's content shape by default.
                .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
