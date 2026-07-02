import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .frame(minWidth: 220)
        } detail: {
            if let id = model.selectedWorkspaceID,
               let workspace = model.workspaces.first(where: { $0.id == id }) {
                WorkspaceDetailView(model: model, workspace: workspace)
            } else {
                EmptyStateView(onAddFolder: { model.presentAddFolderPanel() })
            }
        }
    }
}
