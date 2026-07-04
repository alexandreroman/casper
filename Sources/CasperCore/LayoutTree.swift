import Foundation

/// Pure operations on a workspace's `LayoutNode` tree. No UI; fully testable.
/// Every leaf holds exactly one surface. Each operation returns a new tree and
/// the surface id that should hold focus.
public enum LayoutTree {
    public enum InsertSide: Equatable { case before, after }

    /// All surface ids in visual (depth-first) order.
    public static func surfaceIDs(_ node: LayoutNode) -> [UUID] {
        switch node {
        case .leaf(let surface):
            return [surface.id]
        case .split(_, let children, _):
            return children.flatMap { surfaceIDs($0) }
        }
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
        let newLeaf = LayoutNode.leaf(surface)

        // Root itself is the target leaf: no parent to flatten into.
        if case .leaf(let s) = node, s.id == focused {
            return (pair(orientation, node, newLeaf, side), surface.id)
        }
        guard case .split(let splitOrientation, var children, let ratios) = node else {
            return (node, focused)
        }
        for i in children.indices {
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
            if surfaceIDs(children[i]).contains(focused) {
                let (child, f) = split(children[i], focused: focused,
                                       orientation: orientation, side: side, surface: surface)
                children[i] = child
                return (.split(orientation: splitOrientation, children: children,
                               ratios: ratios), f)
            }
        }
        return (node, focused)
    }

    /// Remove the leaf holding `surface`, dropping its ratio and replacing a
    /// single-child split by its surviving child. Returns `nil` when the tree
    /// becomes empty (caller closes the workspace).
    public static func closeSurface(
        _ node: LayoutNode, surface id: UUID
    ) -> (node: LayoutNode?, focus: UUID?) {
        switch node {
        case .leaf(let surface):
            return surface.id == id ? (nil, nil) : (node, nil)
        case .split(let orientation, var children, var ratios):
            for i in children.indices where surfaceIDs(children[i]).contains(id) {
                let (child, f) = closeSurface(children[i], surface: id)
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
            return (node, nil)
        }
    }

    /// Return a copy of the tree with the surface `id` replaced by `transform(s)`.
    public static func mapSurface(
        _ node: LayoutNode, id: UUID, _ transform: (Surface) -> Surface
    ) -> LayoutNode {
        switch node {
        case .leaf(let surface):
            return .leaf(surface.id == id ? transform(surface) : surface)
        case .split(let o, let children, let ratios):
            return .split(
                orientation: o, children: children.map { mapSurface($0, id: id, transform) },
                ratios: ratios)
        }
    }

    // MARK: - Helpers

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
