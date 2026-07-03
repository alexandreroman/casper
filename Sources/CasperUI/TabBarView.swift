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
                    titles: surfaces.map { title($0) }, activeIndex: activeIndex,
                    onSelect: { idx in
                        model.focusSurface(surfaces[idx].id)
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
        if let runtime = model.runtime, case .terminal = surface.kind {
            GhosttySurfaceRepresentable(
                runtime: runtime,
                configuration: model.surfaceConfiguration(for: workspace, terminal: surface),
                surfaceID: surface.id,
                onFocus: { model.focusSurface($0) })
            .id(surface.id)
        } else {
            // Browser/diff surfaces arrive in UI-4/UI-5.
            ContentUnavailableView(
                "Unsupported surface", systemImage: "rectangle.dashed",
                description: Text("Browser and diff surfaces arrive in UI-4/UI-5."))
        }
    }

    private func title(_ surface: Surface) -> String {
        switch surface.kind {
        case .terminal: return "Terminal"
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
