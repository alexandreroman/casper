import CasperCore
import CasperGhostty
import SwiftUI

struct WorkspaceDetailView: View {
    @Bindable var model: AppModel
    let workspace: Workspace

    var body: some View {
        LayoutNodeView(model: model, workspace: workspace, node: workspace.layout)
    }
}
