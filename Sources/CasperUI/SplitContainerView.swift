import AppKit
import CasperCore
import SwiftUI

/// A custom split renderer for a `LayoutNode.split`, mirroring Ghostty's macOS
/// `SplitView` (the reference implementation) generalized from a binary split to
/// this project's N-ary `LayoutNode`.
///
/// Panes and dividers live in a `ZStack(alignment: .topLeading)`: each pane is
/// placed with an explicit, non-overlapping `.frame(…).offset(…)` (libghostty's
/// Metal-backed views must never overlap or they occlude each other), and each
/// divider is a top-most child placed with `.position(center)`. A divider is the
/// SwiftUI-drawn 1pt separator line plus a transparent AppKit `SplitterHandle`
/// (`SplitterHandleView`) layered on top: the handle's `NSView` bounds are the
/// wider grab strip, so default AppKit hit-testing captures clicks there for the
/// resize while the rest of each pane falls through to the terminal underneath.
/// The handle owns the resize cursor, the drag, and double-click-to-equalize — a
/// concrete `NSView` is required because a SwiftUI `.pointerStyle` loses the cursor
/// to the terminal surface's own `cursorUpdate` (see the terminal-overlay-cursor
/// note).
///
/// The visible 1pt line is filled with `NSColor.separatorColor` so every separator
/// in the app — sidebar edge, inspector edge, and the terminal splits — reads as
/// the same colour.
///
/// A resize drives the live drag via local `@State fractions`, and additionally
/// writes the new fractions back to the model (`AppModel.setSplitRatios`) so the
/// dragged (or double-click-equalized) divider positions persist to `session.json`
/// and survive an app restart.
struct SplitContainerView: View {
    let model: AppModel
    let workspace: Workspace
    /// Child-index path from the workspace's root layout to this split node
    /// (root = `[]`), used to address it in `AppModel.setSplitRatios`.
    let path: [Int]
    let orientation: LayoutNode.Orientation
    let children: [LayoutNode]
    let ratios: [Double]

    /// Smallest length a pane may shrink to during a resize drag.
    private static let minPaneLength: CGFloat = 60
    /// Thickness of the visible divider line (Ghostty's `splitterVisibleSize`).
    private static let splitterVisibleSize: CGFloat = 1
    /// Extra transparent thickness straddling the line, widening the grab target;
    /// the hitbox is visible + invisible. Deliberate deviation from Ghostty (whose
    /// `splitterInvisibleSize` is 6, a 7pt hitbox): Casper widens it to an 18pt hitbox
    /// for an easier grab. It straddles the line symmetrically, reaching 9pt into each
    /// pane — kept short enough that it stays clear of the pane drag-grip's dots
    /// (`PaneDragHandleView`, a 24pt band at the pane's top edge, dots centered ~y=12).
    private static let splitterInvisibleSize: CGFloat = 17

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
                LayoutNodeView(model: model, workspace: workspace, node: only, path: path + [0])
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
        let view = LayoutNodeView(model: model, workspace: workspace, node: node, path: path + [index])
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

    /// A divider centred on boundary `index`: the SwiftUI-drawn 1pt separator line
    /// plus, on top, an AppKit `SplitterHandle` spanning the wider hit strip. The
    /// handle owns the resize cursor, the drag, and double-click-to-equalize — a
    /// concrete `NSView` is required so the cursor wins over the terminal surface's
    /// own `cursorUpdate` (a SwiftUI `.pointerStyle` cannot; see the
    /// terminal-overlay-cursor note). Positioned with `.position(center)`.
    private func divider(
        index: Int, boundaries: [CGFloat], axisLength: CGFloat, crossLength: CGFloat
    ) -> some View {
        let boundary = boundaries[index]
        let hitThickness = Self.splitterVisibleSize + Self.splitterInvisibleSize
        let center: CGPoint = orientation == .horizontal
            ? CGPoint(x: boundary, y: crossLength / 2)
            : CGPoint(x: crossLength / 2, y: boundary)
        return ZStack {
            // Visible 1pt line, drawn by SwiftUI behind the transparent handle.
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(
                    width: orientation == .horizontal ? Self.splitterVisibleSize : crossLength,
                    height: orientation == .horizontal ? crossLength : Self.splitterVisibleSize)
            // Transparent AppKit grab strip: cursor + drag + double-click.
            SplitterHandle(
                orientation: orientation,
                boundary: boundary,
                onResize: { target in
                    let resized = Self.resizedFractions(
                        displayFractions(), dividerIndex: index, boundaryTarget: target,
                        axisLength: axisLength, minLength: Self.minPaneLength)
                    fractions = resized  // drives the live drag feel
                    model.setSplitRatios(at: path, ratios: resized, for: workspace.id)  // persists it
                },
                onEqualize: {
                    let even = LayoutNode.evenRatios(children.count)
                    fractions = even
                    model.setSplitRatios(at: path, ratios: even, for: workspace.id)
                })
                .frame(
                    width: orientation == .horizontal ? hitThickness : crossLength,
                    height: orientation == .horizontal ? crossLength : hitThickness)
        }
        .position(center)
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

/// SwiftUI wrapper hosting one divider's AppKit `SplitterHandleView`.
private struct SplitterHandle: NSViewRepresentable {
    let orientation: LayoutNode.Orientation
    let boundary: CGFloat
    let onResize: (CGFloat) -> Void
    let onEqualize: () -> Void

    func makeNSView(context: Context) -> SplitterHandleView {
        SplitterHandleView(
            orientation: orientation, boundary: boundary,
            onResize: onResize, onEqualize: onEqualize)
    }

    func updateNSView(_ nsView: SplitterHandleView, context: Context) {
        // SwiftUI mutates `boundary` (via fractions) on every layout, including
        // mid-drag; keep the backing view's inputs in sync so a fresh drag starts
        // from the current boundary and the closures capture the latest state.
        nsView.orientation = orientation
        nsView.boundary = boundary
        nsView.onResize = onResize
        nsView.onEqualize = onEqualize
    }
}

/// AppKit grab handle for one split divider, layered above the panes. A concrete
/// `NSView` — not a SwiftUI `.pointerStyle` — is required so the resize cursor wins
/// over the libghostty terminal surface (`GhosttySurfaceView`), a real sibling
/// `NSView` whose `cursorUpdate` tracking area resets the cursor to the I-beam over
/// the strip where the divider overlaps it. Mirrors `PaneDragHandleView`'s cursor
/// discipline (see the "Cursor management for chrome over the terminal" note): set
/// the cursor in BOTH `cursorUpdate` and `mouseEntered`, reset to arrow on exit.
///
/// The view is transparent (the 1pt line is drawn by SwiftUI behind it); its whole
/// `bounds` is the grab zone. The drag and double-click-to-equalize are handled
/// here in AppKit rather than by a SwiftUI `DragGesture`, because a click-through
/// (`hitTest == nil`) view could not win the cursor while an opaque one would steal
/// the mouse-down — so this view owns both.
final class SplitterHandleView: NSView {
    var orientation: LayoutNode.Orientation
    var boundary: CGFloat
    var onResize: (CGFloat) -> Void
    var onEqualize: () -> Void

    /// Captured at `mouseDown` so the drag maps window-space movement onto the axis
    /// independently of the live `boundary`, which SwiftUI mutates mid-drag.
    private var dragStartBoundary: CGFloat = 0
    private var dragStartWindowLocation: NSPoint = .zero

    init(orientation: LayoutNode.Orientation, boundary: CGFloat,
         onResize: @escaping (CGFloat) -> Void, onEqualize: @escaping () -> Void) {
        self.orientation = orientation
        self.boundary = boundary
        self.onResize = onResize
        self.onEqualize = onEqualize
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Top-left origin, matching SwiftUI.
    override var isFlipped: Bool { true }

    /// Resize even when the window is not key, like `PaneDragHandleView`.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Cursor

    /// A `.horizontal` split has a vertical line dragged left/right (columns); a
    /// `.vertical` split has a horizontal line dragged up/down (rows).
    private var resizeCursor: NSCursor {
        orientation == .horizontal ? .columnResize : .rowResize
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeInActiveApp, .inVisibleRect],
            owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { resizeCursor.set() }

    override func mouseEntered(with event: NSEvent) {
        // Also set here, not only in `cursorUpdate`: entering from a region that
        // defines no cursor of its own (e.g. the window toolbar) fires `mouseEntered`
        // but not `cursorUpdate`. Mirrors `PaneDragHandleView`/`GhosttySurfaceView`.
        resizeCursor.set()
    }

    override func mouseExited(with event: NSEvent) {
        // Reset so the resize cursor does not leak onto the terminal; the surface
        // restores its I-beam via its own `cursorUpdate` on re-entry.
        NSCursor.arrow.set()
    }

    // MARK: - Drag

    override func mouseDown(with event: NSEvent) {
        // No `super`: this whole view is the grab strip, so any press begins a
        // resize (or, on a double-click, equalizes the split).
        if event.clickCount == 2 {
            onEqualize()
            return
        }
        dragStartBoundary = boundary
        dragStartWindowLocation = event.locationInWindow
        resizeCursor.set()
    }

    override func mouseDragged(with event: NSEvent) {
        let now = event.locationInWindow
        // Window coordinates are y-up; the vertical-split axis grows downward, so
        // invert dy. The horizontal-split axis (x) shares the window's direction.
        let deltaAxis = orientation == .horizontal
            ? now.x - dragStartWindowLocation.x
            : dragStartWindowLocation.y - now.y
        onResize(dragStartBoundary + deltaAxis)
    }
}
