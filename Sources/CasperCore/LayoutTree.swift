import Foundation

/// Pure operations on a workspace's `LayoutNode` tree. No UI; fully testable.
/// Every operation returns a new tree and the surface id that should hold focus.
public enum LayoutTree {
    public enum InsertSide: Equatable { case before, after }

    /// All surface ids in visual (depth-first) order.
    public static func surfaceIDs(_ node: LayoutNode) -> [UUID] {
        switch node {
        case .tabGroup(let surfaces, _):
            return surfaces.map(\.id)
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

    /// Append `surface` to the tab group containing `focused`, activate it.
    public static func insertTab(
        _ node: LayoutNode, focused: UUID, surface: Surface
    ) -> (LayoutNode, focus: UUID) {
        switch node {
        case .tabGroup(var surfaces, _):
            guard surfaces.contains(where: { $0.id == focused }) else {
                return (node, focused)
            }
            surfaces.append(surface)
            return (.tabGroup(surfaces: surfaces, activeIndex: surfaces.count - 1),
                    surface.id)
        case .split(let orientation, var children, let ratios):
            for i in children.indices where surfaceIDs(children[i]).contains(focused) {
                let (child, f) = insertTab(children[i], focused: focused, surface: surface)
                children[i] = child
                return (.split(orientation: orientation, children: children, ratios: ratios), f)
            }
            return (node, focused)
        }
    }

    /// Split the tab group containing `focused` along `orientation`, inserting a
    /// new single-surface group on `side`. Flat sibling insertion when the parent
    /// split already has that orientation; otherwise a fresh nested 2-child split.
    public static func split(
        _ node: LayoutNode, focused: UUID,
        orientation: LayoutNode.Orientation, side: InsertSide, surface: Surface
    ) -> (LayoutNode, focus: UUID) {
        let newGroup = LayoutNode.tabGroup(surfaces: [surface], activeIndex: 0)

        // Root itself is the target tab group: no parent to flatten into.
        if case .tabGroup(let surfaces, _) = node,
           surfaces.contains(where: { $0.id == focused }) {
            return (pair(orientation, node, newGroup, side), surface.id)
        }
        guard case .split(let splitOrientation, var children, var ratios) = node else {
            return (node, focused)
        }
        for i in children.indices {
            if case .tabGroup(let surfaces, _) = children[i],
               surfaces.contains(where: { $0.id == focused }) {
                if splitOrientation == orientation {
                    let at = side == .after ? i + 1 : i
                    children.insert(newGroup, at: at)
                    return (.split(orientation: splitOrientation, children: children,
                                   ratios: even(children.count)), surface.id)
                }
                children[i] = pair(orientation, children[i], newGroup, side)
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

    /// Remove `surface`, collapsing an emptied group out of its parent split and
    /// replacing a single-child split by its child. Returns `nil` when the tree
    /// becomes empty (caller closes the workspace).
    public static func closeSurface(
        _ node: LayoutNode, surface id: UUID
    ) -> (node: LayoutNode?, focus: UUID?) {
        switch node {
        case .tabGroup(var surfaces, let activeIndex):
            guard let idx = surfaces.firstIndex(where: { $0.id == id }) else {
                return (node, nil)
            }
            surfaces.remove(at: idx)
            if surfaces.isEmpty { return (nil, nil) }
            var active = activeIndex
            if idx < active { active -= 1 }
            active = min(active, surfaces.count - 1)
            return (.tabGroup(surfaces: surfaces, activeIndex: active), surfaces[active].id)
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
                               ratios: even(children.count)),
                        surfaceIDs(focusChild).first)
            }
            return (node, nil)
        }
    }

    /// Set the `activeIndex` of the tab group containing `surface` to that surface.
    public static func activate(_ node: LayoutNode, surface id: UUID) -> LayoutNode {
        switch node {
        case .tabGroup(let surfaces, _):
            guard let idx = surfaces.firstIndex(where: { $0.id == id }) else { return node }
            return .tabGroup(surfaces: surfaces, activeIndex: idx)
        case .split(let orientation, var children, let ratios):
            for i in children.indices where surfaceIDs(children[i]).contains(id) {
                children[i] = activate(children[i], surface: id)
                return .split(orientation: orientation, children: children, ratios: ratios)
            }
            return node
        }
    }

    // MARK: - Helpers

    private static func even(_ n: Int) -> [Double] {
        Array(repeating: 1.0 / Double(n), count: n)
    }

    private static func pair(
        _ orientation: LayoutNode.Orientation, _ existing: LayoutNode,
        _ newGroup: LayoutNode, _ side: InsertSide
    ) -> LayoutNode {
        let children = side == .after ? [existing, newGroup] : [newGroup, existing]
        return .split(orientation: orientation, children: children, ratios: even(2))
    }
}

/// Direction abstraction so CasperCore's `LayoutTree` does not depend on
/// CasperGhostty. CasperUI maps `GhosttySplitDirection` onto this.
public enum GhosttySplitDirectionLike: Equatable { case right, down, left, up }

extension LayoutNode {
    /// A stable identity anchor for SwiftUI ForEach: the first surface id in the
    /// subtree (surface ids are unique across a workspace's tree).
    public var stableID: UUID { LayoutTree.surfaceIDs(self).first ?? UUID() }
}
