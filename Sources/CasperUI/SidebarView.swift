import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: $model.selectedWorkspaceID) {
            ForEach(model.allWorkspaces) { workspace in
                WorkspaceRow(workspace: workspace)
                    .tag(workspace.id)
                    .contextMenu {
                        Button("Remove", role: .destructive) {
                            if let space = model.spaces.first(
                                where: { $0.workspaces.contains(where: { $0.id == workspace.id }) }) {
                                model.removeSpace(id: space.id)
                            }
                        }
                    }
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    model.presentAddFolderPanel()
                } label: {
                    Label("Add folder…", systemImage: "plus")
                }
            }
        }
        .navigationTitle("Casper")
    }
}
