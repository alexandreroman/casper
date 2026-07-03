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

/// A horizontal tab bar styled after Ghostty's terminal tabs: flush,
/// full-height segments that share the bar width equally, the active tab lit and
/// inactive tabs dimmed (no accent color, no border around the active tab), a
/// leading hover-revealed close button, and a trailing "+" menu.
struct TabBarView: View {
    let titles: [String]
    let activeIndex: Int
    let onSelect: (Int) -> Void
    let onClose: (Int) -> Void
    let onNewTerminal: () -> Void
    let onNewBrowser: () -> Void
    let onNewDiff: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(titles.enumerated()), id: \.offset) { idx, title in
                TabItem(
                    title: title,
                    isActive: idx == activeIndex,
                    isLast: idx == titles.count - 1,
                    onSelect: { onSelect(idx) },
                    onClose: { onClose(idx) })
            }
            Menu {
                Button("New terminal", action: onNewTerminal)
                Button("New browser", action: onNewBrowser)
                Button("New diff", action: onNewDiff)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(TabPalette.titleInactive)
                    .frame(width: 30, height: TabPalette.height)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .frame(height: TabPalette.height)
        .background(TabPalette.bar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(TabPalette.bottomBorder).frame(height: 1)
        }
    }
}

/// Colors and metrics for the Ghostty-style tab bar. A fixed dark chrome so the
/// bar matches the (dark by default) embedded terminal regardless of the macOS
/// light/dark appearance — mirroring how Ghostty derives its tab colors from the
/// terminal background. All shades come from one neutral gray: the active tab is
/// lightened, inactive tabs darkened.
private enum TabPalette {
    static let height: CGFloat = 28
    static let bar = Color(white: 0.12)
    static let active = Color(white: 0.20)
    static let inactive = Color(white: 0.09)
    static let inactiveHover = Color(white: 0.15)
    static let titleActive = Color(white: 0.95)
    static let titleInactive = Color(white: 0.58)
    static let separator = Color.black.opacity(0.35)
    static let bottomBorder = Color.black.opacity(0.45)
}

/// A single Ghostty-style tab: full-height, equal width, centered title. The
/// active tab is lit; inactive tabs are dimmed and carry a hairline separator on
/// their trailing edge (hidden on the active tab and the last tab). A close
/// button floats at the leading edge, revealed only on hover so it never shifts
/// the centered title, and it never triggers selection.
private struct TabItem: View {
    let title: String
    let isActive: Bool
    let isLast: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(isActive ? TabPalette.titleActive : TabPalette.titleInactive)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 22)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .background(background)
        .overlay(alignment: .trailing) {
            if !isActive && !isLast {
                Rectangle().fill(TabPalette.separator).frame(width: 1)
            }
        }
        .overlay(alignment: .leading) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(TabPalette.titleInactive)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            .padding(.leading, 5)
        }
        .onHover { hovering = $0 }
    }

    private var background: Color {
        if isActive { return TabPalette.active }
        return hovering ? TabPalette.inactiveHover : TabPalette.inactive
    }
}
