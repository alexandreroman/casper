import CasperCore
import CasperGhostty
import SwiftUI

/// A tab group: an always-visible tab bar over a ZStack of all the group's
/// surfaces, only the active one visible so inactive PTYs stay alive.
struct TabGroupView: View {
    @Bindable var model: AppModel
    let workspace: Workspace
    let surfaces: [Surface]
    let activeIndex: Int

    var body: some View {
        VStack(spacing: 0) {
            TabBarView(
                titles: surfaces.enumerated().map { idx, s in label(s, idx) },
                activeIndex: activeIndex,
                onSelect: { model.setActiveSurface(surfaces[$0].id) },
                onNewTerminal: { model.applyNewTab(anchor: surfaces[activeIndex].id) },
                onNewBrowser: { model.applyNewBrowser(anchor: surfaces[activeIndex].id) })
            ZStack {
                ForEach(Array(surfaces.enumerated()), id: \.element.id) { idx, surface in
                    surfaceView(surface)
                        .opacity(idx == activeIndex ? 1 : 0)
                        .allowsHitTesting(idx == activeIndex)
                }
            }
        }
    }

    @ViewBuilder
    private func surfaceView(_ surface: Surface) -> some View {
        if let view = model.surfaceView(for: surface, in: workspace) {
            PersistentNSViewHost(view: view).id(surface.id)
        } else if case .terminal = surface.kind {
            Color.black  // runtime not ready yet
        } else if case .browser = surface.kind {
            BrowserSurfaceView(model: model, surface: surface)
        } else {
            ContentUnavailableView(
                "Unsupported surface", systemImage: "rectangle.dashed",
                description: Text("Diff surfaces arrive in UI-5."))
        }
    }

    /// A tab's label: a 1-based ordinal within the group, indexed by kind.
    private func label(_ surface: Surface, _ index: Int) -> String {
        switch surface.kind {
        case .terminal: return "Terminal \(index + 1)"
        case .browser: return "Browser \(index + 1)"
        case .diff: return "Diff \(index + 1)"
        }
    }
}

/// A minimal horizontal tab bar.
struct TabBarView: View {
    let titles: [String]
    let activeIndex: Int
    let onSelect: (Int) -> Void
    let onNewTerminal: () -> Void
    let onNewBrowser: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(titles.enumerated()), id: \.offset) { idx, title in
                Button(action: { onSelect(idx) }) {
                    Text(title).font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(idx == activeIndex ? Color.accentColor.opacity(0.25) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
            Menu {
                Button("New terminal", action: onNewTerminal)
                Button("New browser", action: onNewBrowser)
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
    }
}
