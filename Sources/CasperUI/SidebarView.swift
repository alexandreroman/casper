import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: $model.selectedWorkspaceID) {
            ForEach(model.workspaces) { workspace in
                WorkspaceRow(workspace: workspace)
                    .tag(workspace.id)
                    .contextMenu {
                        Button("Remove", role: .destructive) {
                            model.removeWorkspace(id: workspace.id)
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
