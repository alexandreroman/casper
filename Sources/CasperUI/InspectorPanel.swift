import AppKit
import CasperCore
import SwiftUI

/// The right-side inspector panel for a workspace: a top separator continuing
/// the workspace title bar's line, then a segmented Diff | Browser selector
/// centred at the top of the panel, over full-bleed content below.
/// The Browser view reuses `BrowserSurfaceView` on the workspace's dedicated
/// inspector surface; the Diff view reuses `DiffSurfaceView` for the working
/// tree vs HEAD. Shown by `WorkspaceDetailView` only when the inspector is expanded.
struct InspectorPanel: View {
    let model: AppModel
    let workspace: Workspace

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
            Picker("View", selection: tabSelection) {
                Text("Diff").tag(InspectorTab.diff)
                Text("Browser").tag(InspectorTab.browser)
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
