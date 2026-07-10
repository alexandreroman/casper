import CasperCore
import SwiftUI

/// A Space group header. A disclosure chevron and the folder/repo name toggle
/// collapse on tap; an expanded Git Space also shows a trailing "+" to add a
/// linked workspace. The "+" lives in the same 20pt trailing slot as each row's
/// notification bubble so both align on one vertical column.
struct SpaceHeaderView: View {
    @Bindable var model: AppModel
    let space: Space

    var body: some View {
        HStack(spacing: 8) {
            // Chevron glyph stays ~12pt, but its slot is 16pt wide to match the
            // rows' 16pt leading Octicon so the Space name lines up under each
            // row's branch label. The `.snappy` collapse toggle (driven by
            // `withAnimation` in `toggleSpaceCollapsed`) animates this rotation.
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(space.isCollapsed ? 0 : 90))
                .frame(width: 16)

            Text(space.name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            trailingSlot
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 14)
        // The "+" button intercepts its own tap; the rest of the row toggles collapse.
        .contentShape(Rectangle())
        .onTapGesture { model.toggleSpaceCollapsed(id: space.id) }
    }

    /// Fixed 20pt trailing slot that aligns with the rows' notification bubbles.
    /// Holds the "+" only for an expanded Git Space; otherwise it stays empty so
    /// the column width is stable.
    @ViewBuilder private var trailingSlot: some View {
        ZStack {
            if space.isGitRepo && !space.isCollapsed {
                Button {
                    model.presentAddLinkedWorkspacePanel(spaceID: space.id)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Create Workspace")
            }
        }
        .frame(width: 20)
    }
}
