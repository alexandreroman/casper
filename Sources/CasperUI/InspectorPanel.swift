import CasperCore
import SwiftUI

/// The right-side inspector panel for a workspace: a native segmented
/// Browser | Diff selector pinned to the top over full-bleed content. The
/// Browser view reuses `BrowserSurfaceView` on the workspace's dedicated
/// inspector surface; the Diff view reuses `DiffSurfaceView` for the working
/// tree vs HEAD. Content fills the panel edge-to-edge below the selector.
/// Shown by `WorkspaceDetailView` only when the workspace's inspector is expanded.
struct InspectorPanel: View {
    let model: AppModel
    let workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: tabSelection) {
                Text("Browser").tag(InspectorTab.browser)
                Text("Diff").tag(InspectorTab.diff)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var content: some View {
        switch workspace.inspector.tab {
        case .browser:
            BrowserSurfaceView(model: model, surface: workspace.inspector.browser)
        case .diff:
            DiffSurfaceView(model: model, workspace: workspace)
        }
    }

    /// Bridges the persisted tab to the segmented selector: writing routes
    /// through `setInspectorTab`, which also keeps the panel expanded.
    private var tabSelection: Binding<InspectorTab> {
        Binding(
            get: { workspace.inspector.tab },
            set: { model.setInspectorTab($0, for: workspace.id) })
    }
}
