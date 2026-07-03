import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel

    /// Per-Space expansion state, keyed by space id. Missing means expanded, so
    /// newly added Spaces start open.
    @State private var expanded: [UUID: Bool] = [:]

    var body: some View {
        List(selection: $model.selectedWorkspaceID) {
            ForEach(model.spaces) { space in
                Section(isExpanded: expansion(space.id)) {
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
                    Label("Add a Space", systemImage: "folder.badge.plus")
                }
                .help("Add a Space")
            }
        }
        .navigationTitle("Casper")
    }

    private func expansion(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { expanded[id] ?? true },
            set: { expanded[id] = $0 })
    }
}
