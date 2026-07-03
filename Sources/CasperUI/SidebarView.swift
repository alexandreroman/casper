import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel

    /// Per-Space expansion state, keyed by space id. Missing means expanded, so
    /// newly added Spaces start open.
    @State private var expanded: [UUID: Bool] = [:]

    var body: some View {
        // Route selection through `selectWorkspace` (not a plain `$model` binding)
        // so picking a workspace also moves keyboard focus to its top-left terminal.
        List(selection: Binding(
            get: { model.selectedWorkspaceID },
            set: { model.selectWorkspace($0) }
        )) {
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
        .navigationTitle("Casper")
    }

    private func expansion(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { expanded[id] ?? true },
            set: { expanded[id] = $0 })
    }
}
