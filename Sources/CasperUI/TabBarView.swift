import CasperCore
import CasperGhostty
import SwiftUI

/// A tab group: an optional tab bar (when >1 surface) over a ZStack of all the
/// group's surfaces, only the active one visible so inactive PTYs stay alive.
struct TabGroupView: View {
    @Bindable var model: AppModel
    let workspace: Workspace
    let surfaces: [Surface]
    let activeIndex: Int

    var body: some View {
        VStack(spacing: 0) {
            if surfaces.count > 1 {
                TabBarView(
                    titles: surfaces.enumerated().map { title($1, index: $0) },
                    activeIndex: activeIndex,
                    onSelect: { idx in
                        model.setActiveSurface(surfaces[idx].id)
                    })
            }
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
            GhosttySurfaceHostView(surfaceView: view).id(surface.id)
        } else if case .terminal = surface.kind {
            Color.black  // runtime not ready yet
        } else {
            ContentUnavailableView(
                "Unsupported surface", systemImage: "rectangle.dashed",
                description: Text("Browser and diff surfaces arrive in UI-4/UI-5."))
        }
    }

    /// A tab's label: terminals get a 1-based ordinal within the group;
    /// browser/diff surfaces are labeled by kind (they are singletons for now).
    private func title(_ surface: Surface, index: Int) -> String {
        switch surface.kind {
        case .terminal: return "Terminal \(index + 1)"
        case .browser: return "Browser"
        case .diff: return "Diff"
        }
    }
}

/// A minimal horizontal tab bar.
struct TabBarView: View {
    let titles: [String]
    let activeIndex: Int
    let onSelect: (Int) -> Void

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
            Spacer()
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
    }
}
