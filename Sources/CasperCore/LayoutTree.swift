import Foundation

/// Pure operations on a workspace's `LayoutNode` tree. No UI; fully testable.
/// Every leaf holds exactly one surface. Each operation returns a new tree and
/// the surface id that should hold focus.
public enum LayoutTree {
    public enum InsertSide: Equatable { case before, after }

    /// Visits every surface in visual (depth-first) order without building any
    /// array. Prefer it over `surfaces` whenever the caller only reads each
    /// surface: no per-level throwaway array, and no copy of the `Surface` values.
    public static func forEachSurface(_ node: LayoutNode, _ body: (Surface) -> Void) {
        switch node {
        case .leaf(let surface):
            body(surface)
        case .split(_, let children, _):
            for child in children { forEachSurface(child, body) }
        }
    }

    /// All surface ids in visual (depth-first) order.
    public static func surfaceIDs(_ node: LayoutNode) -> [UUID] {
        var ids: [UUID] = []
        forEachSurface(node) { ids.append($0.id) }
        return ids
    }

    /// All surfaces in visual (depth-first) order.
    public static func surfaces(_ node: LayoutNode) -> [Surface] {
        var result: [Surface] = []
        forEachSurface(node) { result.append($0) }
        return result
    }

    /// Replace the surface with `id` in the tree by applying `transform` to
    /// it in place. Leaves the tree structurally unchanged (same shape,
    /// values equal) if `id` is not found — the `Surface`-mutating twin of
    /// `surfaceIDs`/`surfaces`, walking the same cases.
    public static func updateSurface(
        _ node: LayoutNode, id: UUID, _ transform: (inout Surface) -> Void
    ) -> LayoutNode {
        switch node {
        case .leaf(var surface):
            if surface.id == id { transform(&surface) }
            return .leaf(surface)
        case .split(let orientation, let children, let ratios):
            return .split(
                orientation: orientation,
                children: children.map { updateSurface($0, id: id, transform) },
                ratios: ratios)
        }
    }

    /// Replace the `ratios` of the `.split` node reached by walking `path` — the
    /// sequence of child indices from the root (`[]` targets the root itself).
    /// Returns the tree unchanged when the path does not resolve to a node, the
    /// target is not a `.split`, or the target's child count differs from
    /// `ratios.count`. Follows the functional style of the other operations here:
    /// a new tree, never an in-place mutation.
    public static func updateRatios(
        in tree: LayoutNode, at path: [Int], ratios: [Double]
    ) -> LayoutNode {
        updateRatios(in: tree, at: path[...], ratios: ratios)
    }

    /// Recursive core of `updateRatios`, walking the path as a slice so descending
    /// a level is a bounds adjustment rather than a fresh array per depth.
    private static func updateRatios(
        in tree: LayoutNode, at path: ArraySlice<Int>, ratios: [Double]
    ) -> LayoutNode {
        guard let index = path.first else {
            // Empty path: `tree` is the target split whose ratios we replace.
            guard case .split(let orientation, let children, _) = tree,
                  children.count == ratios.count else {
                return tree
            }
            return .split(orientation: orientation, children: children, ratios: ratios)
        }
        guard case .split(let orientation, var children, let currentRatios) = tree,
              children.indices.contains(index) else {
            return tree
        }
        children[index] = updateRatios(
            in: children[index], at: path.dropFirst(), ratios: ratios)
        return .split(orientation: orientation, children: children, ratios: currentRatios)
    }

    /// Map a Ghostty split direction to an orientation and insertion side.
    public static func orientationAndSide(
        for direction: GhosttySplitDirectionLike
    ) -> (LayoutNode.Orientation, InsertSide) {
        switch direction {
        case .right: return (.horizontal, .after)
        case .left: return (.horizontal, .before)
        case .down: return (.vertical, .after)
        case .up: return (.vertical, .before)
        }
    }

    /// Split the leaf holding `focused` along `orientation`, inserting a new
    /// `.leaf(surface)` on `side`. Flat sibling insertion when the parent split
    /// already has that orientation; otherwise a fresh nested 2-child split.
    public static func split(
        _ node: LayoutNode, focused: UUID,
        orientation: LayoutNode.Orientation, side: InsertSide, surface: Surface
    ) -> (LayoutNode, focus: UUID) {
        splitting(node, focused: focused, orientation: orientation, side: side, surface: surface)
            ?? (node, focused)
    }

    /// Recursive core of `split`, returning nil when `focused` is not in this
    /// subtree. Reporting the miss in the return value is what lets each subtree be
    /// walked once: probing with `contains` first and then recursing into the same
    /// subtree walked every matching branch twice.
    private static func splitting(
        _ node: LayoutNode, focused: UUID,
        orientation: LayoutNode.Orientation, side: InsertSide, surface: Surface
    ) -> (LayoutNode, focus: UUID)? {
        let newLeaf = LayoutNode.leaf(surface)

        // Root itself is the target leaf: no parent to flatten into.
        if case .leaf(let s) = node {
            guard s.id == focused else { return nil }
            return (pair(orientation, node, newLeaf, side), surface.id)
        }
        guard case .split(let splitOrientation, var children, let ratios) = node else {
            return nil
        }
        for i in children.indices {
            // A matching *direct* child is handled here rather than by the
            // recursion: only the parent knows whether the new leaf can join it as
            // a flat sibling.
            if case .leaf(let s) = children[i], s.id == focused {
                if splitOrientation == orientation {
                    let at = side == .after ? i + 1 : i
                    children.insert(newLeaf, at: at)
                    return (.split(orientation: splitOrientation, children: children,
                                   ratios: LayoutNode.evenRatios(children.count)), surface.id)
                }
                children[i] = pair(orientation, children[i], newLeaf, side)
                return (.split(orientation: splitOrientation, children: children,
                               ratios: ratios), surface.id)
            }
            guard let (child, f) = splitting(children[i], focused: focused,
                                             orientation: orientation, side: side, surface: surface)
            else { continue }
            children[i] = child
            return (.split(orientation: splitOrientation, children: children,
                           ratios: ratios), f)
        }
        return nil
    }

    /// Remove the leaf holding `surface`, dropping its ratio and replacing a
    /// single-child split by its surviving child. Returns `nil` when the tree
    /// becomes empty (the caller re-seeds the workspace with a fresh terminal).
    public static func closeSurface(
        _ node: LayoutNode, surface id: UUID
    ) -> (node: LayoutNode?, focus: UUID?) {
        closing(node, surface: id) ?? (node, nil)
    }

    /// Recursive core of `closeSurface`, returning nil when `id` is not in this
    /// subtree so each subtree is walked once (a `contains` probe followed by a
    /// recursion into the same subtree walked it twice). A hit whose node is nil
    /// means removing the surface emptied the subtree.
    private static func closing(
        _ node: LayoutNode, surface id: UUID
    ) -> (node: LayoutNode?, focus: UUID?)? {
        switch node {
        case .leaf(let surface):
            return surface.id == id ? (nil, nil) : nil
        case .split(let orientation, var children, var ratios):
            for i in children.indices {
                guard let (child, f) = closing(children[i], surface: id) else { continue }
                if let child {
                    children[i] = child
                    return (.split(orientation: orientation, children: children,
                                   ratios: ratios), f)
                }
                children.remove(at: i)
                ratios.remove(at: i)
                if children.count == 1 {
                    let survivor = children[0]
                    return (survivor, surfaceIDs(survivor).first)
                }
                let focusChild = children[min(i, children.count - 1)]
                return (.split(orientation: orientation, children: children,
                               ratios: LayoutNode.evenRatios(children.count)),
                        surfaceIDs(focusChild).first)
            }
            return nil
        }
    }

    /// Relocate the leaf holding `surfaceID` to sit beside `targetID` on the
    /// side implied by `direction`. Removes the source (reusing `closeSurface`'s
    /// removal + single-child collapse), then reinserts the *same* `Surface`
    /// value verbatim — so `Surface.id` is preserved and the cached view/PTY
    /// survives (the surface-identity invariant). Ratios are re-evened by
    /// `split`. Returns `nil` for degenerate moves: source == target, or either
    /// id missing from the tree (before or after removal).
    public static func move(
        _ node: LayoutNode, surfaceID: UUID, toTarget targetID: UUID,
        direction: GhosttySplitDirectionLike
    ) -> (LayoutNode, focus: UUID)? {
        guard surfaceID != targetID else { return nil }
        guard let source = surface(node, id: surfaceID) else { return nil }
        guard contains(node, id: targetID) else { return nil }

        let (reduced, _) = closeSurface(node, surface: surfaceID)
        guard let reduced, contains(reduced, id: targetID) else { return nil }

        let (orientation, side) = orientationAndSide(for: direction)
        return split(reduced, focused: targetID, orientation: orientation, side: side, surface: source)
    }

    /// One of the four triangular edge regions a drop can land in, mirroring
    /// Ghostty's `TerminalSplitDropZone`. There is no center/swap zone.
    public enum DropZone: Equatable {
        case top, bottom, left, right

        /// The split direction a drop in this zone relocates the pane along.
        public var direction: GhosttySplitDirectionLike {
            switch self {
            case .top: return .up
            case .bottom: return .down
            case .left: return .left
            case .right: return .right
            }
        }
    }

    /// The drop zone `point` falls in within a pane of `size`: the nearest edge,
    /// mirroring Ghostty's `TerminalSplitDropZone.calculate`. Ties break in the
    /// order left, right, top, bottom (so the exact center resolves to `.left`).
    /// A zero/negative size defaults to `.left` rather than dividing by zero.
    public static func dropZone(at point: CGPoint, in size: CGSize) -> DropZone {
        guard size.width > 0, size.height > 0 else { return .left }
        let relX = point.x / size.width
        let relY = point.y / size.height
        let left = relX
        let right = 1 - relX
        let top = relY
        let bottom = 1 - relY
        let nearest = min(left, right, top, bottom)
        if nearest == left { return .left }
        if nearest == right { return .right }
        if nearest == top { return .top }
        return .bottom
    }

    // MARK: - Helpers

    /// Whether the subtree rooted at `node` holds a surface with `id`. Stops at the
    /// first match instead of materializing every id like `surfaceIDs`.
    private static func contains(_ node: LayoutNode, id: UUID) -> Bool {
        switch node {
        case .leaf(let surface):
            return surface.id == id
        case .split(_, let children, _):
            return children.contains { contains($0, id: id) }
        }
    }

    /// The `Surface` value with `id` from the tree, or `nil` if absent.
    private static func surface(_ node: LayoutNode, id: UUID) -> Surface? {
        switch node {
        case .leaf(let surface):
            return surface.id == id ? surface : nil
        case .split(_, let children, _):
            for child in children {
                if let found = surface(child, id: id) { return found }
            }
            return nil
        }
    }

    private static func pair(
        _ orientation: LayoutNode.Orientation, _ existing: LayoutNode,
        _ newLeaf: LayoutNode, _ side: InsertSide
    ) -> LayoutNode {
        let children = side == .after ? [existing, newLeaf] : [newLeaf, existing]
        return .split(orientation: orientation, children: children, ratios: LayoutNode.evenRatios(2))
    }
}

/// Direction abstraction so CasperCore's `LayoutTree` does not depend on
/// CasperGhostty. CasperUI maps `GhosttySplitDirection` onto this.
public enum GhosttySplitDirectionLike: Equatable { case right, down, left, up }
