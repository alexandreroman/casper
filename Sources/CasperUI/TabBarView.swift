import CasperCore
import CasperGhostty
import SwiftUI

/// A tab group: an always-visible tab bar over the single active surface.
///
/// Only the active surface is rendered. Inactive surfaces stay alive in
/// `AppModel`'s persistent view cache (`surfaceViews` / `browserCoordinators`),
/// so their PTYs/navigation keep running in the background — libghostty reads
/// the PTY independently of rendering — and they re-attach when re-selected.
/// This avoids stacking multiple Metal-backed terminal layers: a `CAMetalLayer`
/// keeps compositing on the GPU regardless of SwiftUI `.opacity`, so an
/// inactive surface layered on top of the active one would occlude it even
/// while "hidden".
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
                onClose: { model.applyCloseSurface(surfaces[$0].id) },
                onNewTerminal: { model.applyNewTab(anchor: surfaces[activeIndex].id) },
                onNewBrowser: { model.applyNewBrowser(anchor: surfaces[activeIndex].id) },
                onNewDiff: { model.applyNewDiff(anchor: surfaces[activeIndex].id) })
            activeSurface
        }
    }

    @ViewBuilder
    private var activeSurface: some View {
        let index = surfaces.indices.contains(activeIndex) ? activeIndex : 0
        if surfaces.indices.contains(index) {
            surfaceView(surfaces[index])
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        } else if case .diff = surface.kind {
            DiffSurfaceView(model: model, workspace: workspace)
        } else {
            ContentUnavailableView(
                "Unsupported surface", systemImage: "rectangle.dashed",
                description: Text("This surface kind isn't supported yet."))
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
    let onClose: (Int) -> Void
    let onNewTerminal: () -> Void
    let onNewBrowser: () -> Void
    let onNewDiff: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(titles.enumerated()), id: \.offset) { idx, title in
                TabItem(
                    title: title,
                    isActive: idx == activeIndex,
                    onSelect: { onSelect(idx) },
                    onClose: { onClose(idx) })
            }
            Menu {
                Button("New terminal", action: onNewTerminal)
                Button("New browser", action: onNewBrowser)
                Button("New diff", action: onNewDiff)
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

/// A single tab: its title selects the tab; a close button ("×") is revealed on
/// hover (and stays visible while the tab is active). The close button is a
/// distinct control so it never triggers selection.
private struct TabItem: View {
    let title: String
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onSelect) {
                Text(title).font(.caption)
            }
            .buttonStyle(.plain)

            if hovering || isActive {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.caption2).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(isActive ? Color.accentColor.opacity(0.25) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .onHover { hovering = $0 }
    }
}
