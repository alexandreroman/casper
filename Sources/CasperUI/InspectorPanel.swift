import AppKit
import CasperCore
import SwiftUI

/// The right-side inspector panel for a workspace: a top separator continuing
/// the workspace title bar's line, then a segmented Browser | Diff selector
/// centred at the top of the panel, over full-bleed content below.
/// The Browser view reuses `BrowserSurfaceView` on the workspace's dedicated
/// inspector surface; the Diff view reuses `DiffSurfaceView` for the working
/// tree vs HEAD. Shown by `WorkspaceDetailView` only when the inspector is expanded.
struct InspectorPanel: View {
    let model: AppModel
    let workspace: Workspace

    var body: some View {
        // SwiftUI's native inspector exposes no binding for the user-resized
        // width, and its PreferenceKey propagation across the AppKit-hosted
        // NSSplitView is unreliable (it only ever delivers the default value).
        // So the panel fills a root GeometryReader and reports `proxy.size.width`
        // — which equals the inspector column width — via `onChange`, letting the
        // model clamp and debounce the persist. `onGeometryChange` would be
        // simpler but is macOS 15+; this reads the proxy directly on macOS 14.
        GeometryReader { proxy in
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: 2)
                    .padding(.top, -1)
                    .padding(.leading, 1)
                Picker("View", selection: tabSelection) {
                    Text("Browser").tag(InspectorTab.browser)
                    Text("Diff").tag(InspectorTab.diff)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                Divider()
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: proxy.size.width) { _, width in
                model.setInspectorWidth(width, for: workspace.id)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch workspace.inspector.tab {
        case .browser:
            BrowserSurfaceView(model: model, surface: workspace.inspector.browser)
        case .diff:
            DiffSurfaceView(model: model, workspace: workspace)
        }
    }

    /// Bridges the persisted inspector tab to the segmented selector; writing
    /// routes through `setInspectorTab`, which also keeps the panel expanded.
    private var tabSelection: Binding<InspectorTab> {
        Binding(
            get: { workspace.inspector.tab },
            set: { model.setInspectorTab($0, for: workspace.id) })
    }
}
