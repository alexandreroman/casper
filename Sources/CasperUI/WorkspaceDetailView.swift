import CasperCore
import CasperGhostty
import SwiftUI

struct WorkspaceDetailView: View {
    @Bindable var model: AppModel
    let workspace: Workspace

    var body: some View {
        if let runtime = model.runtime, let terminal = singleTerminal(workspace.layout) {
            GhosttySurfaceRepresentable(
                runtime: runtime,
                configuration: model.surfaceConfiguration(for: workspace, terminal: terminal)
            )
            .id(workspace.id)
        } else {
            // UI-1 only renders the single-terminal tabGroup; nested splits/tabs
            // are UI-3. This branch is unreachable for UI-1-created workspaces.
            ContentUnavailableView(
                "Unsupported layout", systemImage: "rectangle.split.2x1",
                description: Text("Nested splits and tabs arrive in UI-3."))
        }
    }

    /// Extract the sole terminal surface from a UI-1 single-terminal layout.
    private func singleTerminal(_ layout: LayoutNode) -> Surface? {
        guard case .tabGroup(let surfaces, _) = layout, surfaces.count == 1,
              case .terminal = surfaces[0].kind else { return nil }
        return surfaces[0]
    }
}
