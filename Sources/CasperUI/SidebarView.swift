import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: $model.selectedWorkspaceID) {
            ForEach(model.spaces) { space in
                Section {
                    ForEach(space.workspaces) { workspace in
                        WorkspaceRow(workspace: workspace)
                            .tag(workspace.id)
                            .contextMenu {
                                if workspace.kind == .linked {
                                    Button("Remove workspace", role: .destructive) {
                                        model.removeWorkspace(id: workspace.id)
                                    }
                                }
                            }
                    }
                } header: {
                    SpaceHeaderView(model: model, space: space)
                        .contextMenu {
                            Button("Remove space", role: .destructive) {
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
