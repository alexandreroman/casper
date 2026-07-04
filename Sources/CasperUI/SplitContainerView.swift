import AppKit
import CasperCore
import SwiftUI

/// A custom split renderer for a `LayoutNode.split`: lays its children out along
/// `orientation` and separates them with system `Divider()`s, so every separator
/// in the app — sidebar edge, inspector edge, and now the terminal splits — reads
/// as the same `NSColor.separatorColor` line (the native `HSplitView`/`VSplitView`
/// dividers render darker). Interactive resize is preserved via a draggable
/// transparent hit area straddling each divider.
///
/// Resize lives in local `@State` only and is not persisted to the model, matching
/// the v1 behavior where split ratios aren't written back to `session.json`.
struct SplitContainerView: View {
    let model: AppModel
    let workspace: Workspace
    let orientation: LayoutNode.Orientation
    let children: [LayoutNode]
    let ratios: [Double]

    /// Smallest length a pane may shrink to during a resize drag.
    private static let minPaneLength: CGFloat = 60
    /// The system `Divider()` is a 1pt line; account for it when dividing space.
    private static let dividerThickness: CGFloat = 1
    /// Transparent, easier-to-grab drag target straddling each 1pt divider.
    private static let dividerHitThickness: CGFloat = 8

    /// Per-child size fractions along the axis (sum ≈ 1). Seeded from `ratios`
    /// when it matches and is usable, else an even split.
    @State private var fractions: [Double] = []
    /// Snapshot of `fractions` captured at the start of a resize drag, so the
    /// gesture resizes relative to where the divider was when the drag began
    /// rather than accumulating per event (mirrors the inspector's idiom).
    @State private var dragBase: [Double]?

    var body: some View {
        GeometryReader { geometry in
            let axisLength = orientation == .horizontal ? geometry.size.width : geometry.size.height
            let available = axisLength - Self.dividerThickness * CGFloat(children.count - 1)
            content(available: available)
        }
        .onAppear {
            if fractions.isEmpty { fractions = seededFractions() }
        }
        .onChange(of: children.count) {
            fractions = seededFractions()
        }
    }

    @ViewBuilder
    private func content(available: CGFloat) -> some View {
        if children.count < 2 {
            // A split always has ≥2 children; render the sole child defensively.
            if let only = children.first {
                LayoutNodeView(model: model, workspace: workspace, node: only)
            }
        } else if orientation == .horizontal {
            HStack(spacing: 0) { panes(available: available) }
        } else {
            VStack(spacing: 0) { panes(available: available) }
        }
    }

    /// Interleaves the children with dividers: child 0, divider 0, child 1, … .
    /// Each child is sized on the axis to its fraction of `available`; when
    /// `available` isn't known yet (≤ 0), panes fall back to an even, flexible
    /// distribution so terminals never get a zero-width frame.
    @ViewBuilder
    private func panes(available: CGFloat) -> some View {
        let fracs = displayFractions()
        ForEach(Array(children.enumerated()), id: \.offset) { index, child in
            pane(child, fixedLength: available > 0 ? max(0, available * fracs[index]) : nil)
            if index < children.count - 1 {
                divider(index: index, available: available)
            }
        }
    }

    /// A single pane: fixed on the axis (`fixedLength`), stretched on the cross
    /// axis. Panes get explicit, non-overlapping frames — libghostty's
    /// Metal-backed views must not overlap or they occlude each other.
    @ViewBuilder
    private func pane(_ node: LayoutNode, fixedLength: CGFloat?) -> some View {
        let view = LayoutNodeView(model: model, workspace: workspace, node: node)
        switch orientation {
        case .horizontal:
            view
                .frame(width: fixedLength)
                .frame(maxWidth: fixedLength == nil ? .infinity : nil, maxHeight: .infinity)
        case .vertical:
            view
                .frame(height: fixedLength)
                .frame(maxWidth: .infinity, maxHeight: fixedLength == nil ? .infinity : nil)
        }
    }

    /// A system `Divider()` overlaid with a transparent hit area that shows a
    /// resize cursor on hover and drags the two adjacent panes.
    private func divider(index: Int, available: CGFloat) -> some View {
        Divider()
            .overlay {
                Rectangle()
                    .fill(Color.clear)
                    .frame(
                        width: orientation == .horizontal ? Self.dividerHitThickness : nil,
                        height: orientation == .vertical ? Self.dividerHitThickness : nil)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        let cursor = orientation == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown
                        if hovering { cursor.push() } else { NSCursor.pop() }
                    }
                    .gesture(dragGesture(index: index, available: available))
            }
    }

    private func dragGesture(index: Int, available: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if dragBase == nil { dragBase = fractions }
                guard let base = dragBase, available > 0 else { return }
                let translation = orientation == .horizontal ? value.translation.width : value.translation.height
                resize(dividerIndex: index, base: base, delta: translation / available, available: available)
            }
            .onEnded { _ in dragBase = nil }
    }

    /// Moves `delta` (in fraction units) from one neighbor of divider `index` to
    /// the other so the divider follows the cursor, clamped so neither adjacent
    /// pane drops below `minPaneLength`.
    private func resize(dividerIndex index: Int, base: [Double], delta: Double, available: CGFloat) {
        guard base.count == children.count, index + 1 < base.count else { return }
        let minFraction = Double(Self.minPaneLength / available)
        let lower = minFraction - base[index]
        let upper = base[index + 1] - minFraction
        guard upper >= lower else { return }  // panes too small to give either room
        let clamped = min(max(delta, lower), upper)
        fractions[index] = base[index] + clamped
        fractions[index + 1] = base[index + 1] - clamped
    }

    /// Current fractions, falling back to an even split until `@State` is seeded
    /// or when a child-count change momentarily leaves them out of sync.
    private func displayFractions() -> [Double] {
        fractions.count == children.count ? fractions : evenFractions()
    }

    private func seededFractions() -> [Double] {
        guard !children.isEmpty else { return [] }
        let sum = ratios.reduce(0, +)
        if ratios.count == children.count, sum > 0 {
            return ratios.map { $0 / sum }
        }
        return evenFractions()
    }

    private func evenFractions() -> [Double] {
        guard !children.isEmpty else { return [] }
        return LayoutNode.evenRatios(children.count)
    }
}
