import CasperCore
import SwiftUI

/// A Space group header: folder/repo name plus, for Git Spaces, a "+" to add a
/// linked workspace.
struct SpaceHeaderView: View {
    @Bindable var model: AppModel
    let space: Space

    var body: some View {
        HStack {
            Text(space.name).font(.headline).lineLimit(1)
            Spacer()
            if space.isGitRepo {
                Button {
                    model.presentAddLinkedWorkspacePanel(spaceID: space.id)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add a workspace")
            }
        }
    }
}
