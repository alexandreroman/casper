import CasperCore
import SwiftUI

/// A custom split renderer for a `LayoutNode.split`, mirroring Ghostty's macOS
/// `SplitView` (the reference implementation) generalized from a binary split to
/// this project's N-ary `LayoutNode`.
///
/// Panes and dividers live in a `ZStack(alignment: .topLeading)`: each pane is
/// placed with an explicit, non-overlapping `.frame(…).offset(…)` (libghostty's
/// Metal-backed views must never overlap or they occlude each other), and each
/// divider is a top-most child placed with `.position(…)`. The `.position` makes
/// the divider's layout frame fill the parent, so the drag gesture reports its
/// location in the full `GeometryReader` space — the exact geometry the resize
/// math maps against — while `contentShape` keeps the *hittable* region limited to
/// the thin strip, letting pane clicks fall through to the terminal underneath.
/// Attaching `.gesture` *after* `.position` is load-bearing for this to hold.
///
/// The visible 1pt line is filled with `NSColor.separatorColor` so every separator
/// in the app — sidebar edge, inspector edge, and the terminal splits — reads as
/// the same colour.
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
    /// Thickness of the visible divider line (Ghostty's `splitterVisibleSize`).
    private static let splitterVisibleSize: CGFloat = 1
    /// Extra transparent thickness straddling the line, widening the grab target;
    /// the hitbox is visible + invisible. Deliberate deviation from Ghostty (whose
    /// `splitterInvisibleSize` is 6, a 7pt hitbox): Casper widens it to a 12pt hitbox
    /// for an easier grab, kept below ~12pt so it never encroaches on the pane
    /// drag-grip (`PaneDragHandleView`) sitting just past the divider.
    private static let splitterInvisibleSize: CGFloat = 11

    /// Per-child size fractions along the axis (sum ≈ 1). Seeded from `ratios`
    /// when it matches and is usable, else an even split.
    @State private var fractions: [Double] = []

    var body: some View {
        GeometryReader { geometry in
            content(geometry: geometry)
        }
        .onAppear {
            if fractions.isEmpty { fractions = seededFractions() }
        }
        .onChange(of: children.count) {
            fractions = seededFractions()
        }
    }

    @ViewBuilder
    private func content(geometry: GeometryProxy) -> some View {
        if children.count < 2 {
            // A split always has ≥2 children; render the sole child defensively.
            if let only = children.first {
                LayoutNodeView(model: model, workspace: workspace, node: only)
            }
        } else {
            let fracs = displayFractions()
            let axisLength = orientation == .horizontal ? geometry.size.width : geometry.size.height
            let crossLength = orientation == .horizontal ? geometry.size.height : geometry.size.width
            let boundaries = boundaries(fractions: fracs, axisLength: axisLength)
            ZStack(alignment: .topLeading) {
                // Panes first (below), dividers last so they hit-test on top.
                ForEach(Array(children.enumerated()), id: \.element.paneDiffKey) { index, child in
                    pane(child, index: index, boundaries: boundaries,
                         axisLength: axisLength, crossLength: crossLength)
                }
                ForEach(0..<(children.count - 1), id: \.self) { i in
                    divider(index: i, boundaries: boundaries,
                            axisLength: axisLength, crossLength: crossLength)
                }
            }
        }
    }

    /// Cumulative interior boundaries `b[0] … b[N-2]` (in axis points): `b[i]` is
    /// where pane `i` ends and pane `i+1` begins. Conceptually `b[-1] = 0` and
    /// `b[N-1] = axisLength` bound the ends.
    private func boundaries(fractions: [Double], axisLength: CGFloat) -> [CGFloat] {
        guard fractions.count >= 2 else { return [] }
        var result: [CGFloat] = []
        var cumulative = 0.0
        for i in 0..<(fractions.count - 1) {
            cumulative += fractions[i]
            result.append(axisLength * cumulative)
        }
        return result
    }

    /// A single pane, framed to sit strictly inside its two boundaries with a
    /// `splitterVisibleSize` gap so neighbouring Metal views never overlap the
    /// divider line or each other. Fills the full cross axis at cross offset 0.
    @ViewBuilder
    private func pane(
        _ node: LayoutNode, index: Int, boundaries: [CGFloat],
        axisLength: CGFloat, crossLength: CGFloat
    ) -> some View {
        let frame = paneAxisFrame(index: index, boundaries: boundaries, axisLength: axisLength)
        let view = LayoutNodeView(model: model, workspace: workspace, node: node)
        switch orientation {
        case .horizontal:
            view
                .frame(width: frame.length, height: crossLength)
                .offset(x: frame.offset, y: 0)
        case .vertical:
            view
                .frame(width: crossLength, height: frame.length)
                .offset(x: 0, y: frame.offset)
        }
    }

    /// Axis offset and length for pane `index`, leaving a half-`splitterVisibleSize`
    /// gap on each interior side. Lengths clamp to `max(0, …)` so nothing goes
    /// negative before layout settles.
    private func paneAxisFrame(
        index: Int, boundaries: [CGFloat], axisLength: CGFloat
    ) -> (offset: CGFloat, length: CGFloat) {
        let last = children.count - 1
        let half = Self.splitterVisibleSize / 2
        let before = index == 0 ? 0 : boundaries[index - 1]
        let after = index == last ? axisLength : boundaries[index]
        let offset: CGFloat
        let length: CGFloat
        if index == 0 {
            offset = 0
            length = after - half
        } else if index == last {
            offset = before + half
            length = axisLength - before - half
        } else {
            offset = before + half
            length = (after - before) - Self.splitterVisibleSize
        }
        return (offset, max(0, length))
    }

    /// A divider centred on boundary `index`: a thin visible line inside a wider
    /// transparent hit strip. `.position` fills the parent for the drag's
    /// coordinate space; `.gesture`/`.onTapGesture` are attached afterwards.
    private func divider(
        index: Int, boundaries: [CGFloat], axisLength: CGFloat, crossLength: CGFloat
    ) -> some View {
        let boundary = boundaries[index]
        let center: CGPoint = orientation == .horizontal
            ? CGPoint(x: boundary, y: crossLength / 2)
            : CGPoint(x: crossLength / 2, y: boundary)
        return dividerStrip(crossLength: crossLength)
            .position(center)
            .gesture(dragGesture(index: index, axisLength: axisLength))
            // Nice-to-have from Ghostty: double-click equalizes the split.
            .onTapGesture(count: 2) {
                fractions = LayoutNode.evenRatios(children.count)
            }
    }

    /// The divider's visuals: a transparent grab strip (7pt across the axis) whose
    /// `contentShape` limits hit-testing to itself, plus the 1pt separator line
    /// centred within it. Carries the axis resize cursor via `.pointerStyle`.
    private func dividerStrip(crossLength: CGFloat) -> some View {
        let hitThickness = Self.splitterVisibleSize + Self.splitterInvisibleSize
        return ZStack {
            Color.clear
                .frame(
                    width: orientation == .horizontal ? hitThickness : crossLength,
                    height: orientation == .horizontal ? crossLength : hitThickness)
                .contentShape(Rectangle())
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(
                    width: orientation == .horizontal ? Self.splitterVisibleSize : crossLength,
                    height: orientation == .horizontal ? crossLength : Self.splitterVisibleSize)
        }
        .pointerStyle(orientation == .horizontal ? .columnResize : .rowResize)
    }

    /// Drags divider `index` by the *absolute* cursor location (not accumulated
    /// translation), so the divider tracks the pointer exactly.
    private func dragGesture(index: Int, axisLength: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let target = orientation == .horizontal ? value.location.x : value.location.y
                fractions = Self.resizedFractions(
                    displayFractions(), dividerIndex: index, boundaryTarget: target,
                    axisLength: axisLength, minLength: Self.minPaneLength)
            }
    }

    /// Recompute `fractions` after dragging divider `dividerIndex` to
    /// `boundaryTarget` (an absolute axis position). Only boundary `dividerIndex`
    /// moves, so only panes `dividerIndex` and `dividerIndex + 1` change; the
    /// neighbouring boundaries stay fixed and are read back from `fractions` each
    /// call (no drag snapshot needed). The moved boundary is clamped so neither
    /// adjacent pane drops below `minLength`. Returns the input unchanged when the
    /// index is invalid or the pair has no room to move.
    static func resizedFractions(
        _ fractions: [Double], dividerIndex: Int, boundaryTarget: CGFloat,
        axisLength: CGFloat, minLength: CGFloat
    ) -> [Double] {
        guard dividerIndex >= 0, dividerIndex + 1 < fractions.count, axisLength > 0 else {
            return fractions
        }
        // Fixed neighbouring boundaries: b[i-1] (0 at the start) and b[i+1] (the
        // full length at the end).
        let left = axisLength * fractions[..<dividerIndex].reduce(0, +)
        let right = axisLength * fractions[...(dividerIndex + 1)].reduce(0, +)
        let lowerBound = left + minLength
        let upperBound = right - minLength
        guard upperBound >= lowerBound else { return fractions }  // pair too small to move
        let newBoundary = min(max(boundaryTarget, lowerBound), upperBound)
        var result = fractions
        result[dividerIndex] = Double((newBoundary - left) / axisLength)
        result[dividerIndex + 1] = Double((right - newBoundary) / axisLength)
        return result
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

fileprivate extension LayoutNode {
    /// Stable identity for sibling diffing: the surface ids in this subtree.
    /// Keying ForEach by this (not the array index) keeps each pane's view/host
    /// associated with its content across a drag-relocate reorder.
    var paneDiffKey: [UUID] { LayoutTree.surfaceIDs(self) }
}
