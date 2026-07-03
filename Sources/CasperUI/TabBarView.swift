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

/// A horizontal tab bar styled after Ghostty's terminal tabs: rounded "pill"
/// tabs sharing the bar width equally with centered titles, the active tab a
/// filled bordered pill and inactive tabs blended into the dark bar, a leading
/// hover-revealed close button, and a trailing circular "+" menu.
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
                    onSelect: { onSelect(idx) },
                    onClose: { onClose(idx) })
            }
            Menu {
                Button("New terminal", action: onNewTerminal)
                Button("New browser", action: onNewBrowser)
                Button("New diff", action: onNewDiff)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TabPalette.titleInactive)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(TabPalette.plusFill))
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 6)
        }
        .frame(height: TabPalette.height)
        .background(TabPalette.bar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(TabPalette.bottomBorder).frame(height: 1)
        }
    }
}

/// Colors and metrics for the Ghostty-style rounded tab bar. A fixed dark chrome
/// so the bar matches the (dark by default) embedded terminal regardless of the
/// macOS light/dark appearance — mirroring how Ghostty derives its tab colors
/// from the terminal background.
private enum TabPalette {
    static let height: CGFloat = 32
    static let cornerRadius: CGFloat = 7
    static let tabInset: CGFloat = 4
    static let bar = Color(white: 0.12)
    static let activeFill = Color(white: 0.24)
    static let activeStroke = Color(white: 0.42)
    static let hoverFill = Color(white: 0.17)
    static let titleActive = Color(white: 0.96)
    static let titleInactive = Color(white: 0.60)
    static let bottomBorder = Color.black.opacity(0.45)
    static let plusFill = Color(white: 0.20)
}

/// A single Ghostty-style rounded tab: full-height, equal width, centered title.
/// The active tab is a filled, bordered pill; inactive tabs blend into the bar
/// (a faint fill on hover). The whole pill is clickable to select the tab. A
/// close button floats at the leading edge, revealed only on hover so it never
/// shifts the centered title, and it never triggers selection.
private struct TabItem: View {
    let title: String
    let isActive: Bool
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
                .padding(.horizontal, 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: TabPalette.cornerRadius)
                .fill(fill)
                .overlay(
                    RoundedRectangle(cornerRadius: TabPalette.cornerRadius)
                        .strokeBorder(isActive ? TabPalette.activeStroke : .clear, lineWidth: 1))
                .padding(.vertical, TabPalette.tabInset)
                .padding(.horizontal, 2)
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
            .padding(.leading, 8)
        }
        .onHover { hovering = $0 }
    }

    private var fill: Color {
        if isActive { return TabPalette.activeFill }
        return hovering ? TabPalette.hoverFill : .clear
    }
}
