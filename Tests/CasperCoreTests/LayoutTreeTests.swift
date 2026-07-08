import XCTest
@testable import CasperCore

final class LayoutTreeTests: XCTestCase {
    private func term() -> Surface {
        Surface(kind: .terminal(cwd: "/w", command: nil))
    }
    private func leaf(_ surface: Surface) -> LayoutNode {
        .leaf(surface)
    }

    func testSurfaceIDsWalksDepthFirst() {
        let a = term(); let b = term(); let c = term()
        let root = LayoutNode.split(
            orientation: .horizontal,
            children: [leaf(a), .split(orientation: .vertical, children: [leaf(b), leaf(c)],
                                       ratios: [0.5, 0.5])],
            ratios: [0.5, 0.5])
        XCTAssertEqual(LayoutTree.surfaceIDs(root), [a.id, b.id, c.id])
    }

    func testSurfacesReturnsSurfaceObjectsInOrder() {
        let a = term(); let b = term()
        let root = LayoutNode.split(
            orientation: .horizontal, children: [leaf(a), leaf(b)], ratios: [0.5, 0.5])
        let surfaces = LayoutTree.surfaces(root)
        XCTAssertEqual(surfaces, [a, b])  // ids and kinds, in order
        XCTAssertEqual(surfaces.map(\.id), LayoutTree.surfaceIDs(root))  // mirrors the id walk
    }

    // MARK: - updateSurface

    func testUpdateSurfaceMutatesMatchingLeaf() {
        let a = term(); let b = term()
        let root = LayoutNode.split(
            orientation: .horizontal, children: [leaf(a), leaf(b)], ratios: [0.5, 0.5])
        let out = LayoutTree.updateSurface(root, id: a.id) { $0.fontSize = 18 }
        guard case .split(_, let children, _) = out else { return XCTFail() }
        guard case .leaf(let updated) = children[0], case .leaf(let untouched) = children[1] else {
            return XCTFail()
        }
        XCTAssertEqual(updated.fontSize, 18)
        XCTAssertNil(untouched.fontSize)
        XCTAssertEqual(updated.id, a.id)  // identity preserved
    }

    func testUpdateSurfaceUnknownIDIsNoOp() {
        let a = term()
        let root = leaf(a)
        let out = LayoutTree.updateSurface(root, id: UUID()) { $0.fontSize = 18 }
        XCTAssertEqual(out, root)
    }

    func testUpdateSurfaceRecursesIntoNestedSplits() {
        let a = term(); let b = term(); let c = term()
        let nested = LayoutNode.split(
            orientation: .vertical, children: [leaf(b), leaf(c)], ratios: [0.5, 0.5])
        let root = LayoutNode.split(
            orientation: .horizontal, children: [leaf(a), nested], ratios: [0.5, 0.5])
        let out = LayoutTree.updateSurface(root, id: c.id) { $0.fontSize = 22 }
        let surfaces = LayoutTree.surfaces(out)
        XCTAssertEqual(surfaces.first { $0.id == c.id }?.fontSize, 22)
        XCTAssertNil(surfaces.first { $0.id == b.id }?.fontSize)
    }

    func testSplitFromRootLeafWrapsInSplit() {
        let a = term(); let root = leaf(a); let b = term()
        let (out, focus) = LayoutTree.split(
            root, focused: a.id, orientation: .horizontal, side: .after, surface: b)
        guard case .split(let o, let children, let ratios) = out else { return XCTFail() }
        XCTAssertEqual(o, .horizontal)
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(ratios, [0.5, 0.5])
        XCTAssertEqual(LayoutTree.surfaceIDs(out), [a.id, b.id])
        XCTAssertEqual(focus, b.id)
    }

    func testSplitSameOrientationInsertsFlatSibling() {
        let a = term(); let b = term()
        let root = LayoutNode.split(
            orientation: .horizontal, children: [leaf(a), leaf(b)], ratios: [0.5, 0.5])
        let c = term()
        let (out, _) = LayoutTree.split(
            root, focused: a.id, orientation: .horizontal, side: .after, surface: c)
        guard case .split(_, let children, let ratios) = out else { return XCTFail() }
        XCTAssertEqual(children.count, 3)  // flat, not nested
        XCTAssertEqual(LayoutTree.surfaceIDs(out), [a.id, c.id, b.id])
        XCTAssertEqual(ratios.reduce(0, +), 1.0, accuracy: 1e-9)
    }

    func testSplitDifferentOrientationNests() {
        let a = term(); let b = term()
        let root = LayoutNode.split(
            orientation: .horizontal, children: [leaf(a), leaf(b)], ratios: [0.5, 0.5])
        let c = term()
        let (out, _) = LayoutTree.split(
            root, focused: a.id, orientation: .vertical, side: .after, surface: c)
        guard case .split(_, let children, _) = out else { return XCTFail() }
        XCTAssertEqual(children.count, 2)  // a's slot became a nested split
        guard case .split(let innerO, let inner, _) = children[0] else { return XCTFail() }
        XCTAssertEqual(innerO, .vertical)
        XCTAssertEqual(inner.count, 2)
        XCTAssertEqual(LayoutTree.surfaceIDs(out), [a.id, c.id, b.id])
    }

    func testSplitUnknownFocusIsNoOp() {
        let a = term(); let root = leaf(a); let b = term()
        let (out, focus) = LayoutTree.split(
            root, focused: UUID(), orientation: .horizontal, side: .after, surface: b)
        XCTAssertEqual(out, root)
        XCTAssertNotEqual(focus, b.id)
    }

    func testCloseSurfaceCollapsesSingleChildSplit() {
        let a = term(); let b = term()
        let root = LayoutNode.split(
            orientation: .horizontal, children: [leaf(a), leaf(b)], ratios: [0.5, 0.5])
        let (out, focus) = LayoutTree.closeSurface(root, surface: b.id)
        guard case .leaf(let s)? = out else { return XCTFail("expected collapse to leaf") }
        XCTAssertEqual(s.id, a.id)
        XCTAssertEqual(focus, a.id)
    }

    func testCloseSurfaceReEvensRatiosAndFocusesNeighbor() {
        let a = term(); let b = term(); let c = term()
        let root = LayoutNode.split(
            orientation: .horizontal, children: [leaf(a), leaf(b), leaf(c)],
            ratios: [0.2, 0.3, 0.5])
        let (out, focus) = LayoutTree.closeSurface(root, surface: b.id)  // middle
        guard case .split(_, let children, let ratios)? = out else { return XCTFail() }
        XCTAssertEqual(LayoutTree.surfaceIDs(out!), [a.id, c.id])
        XCTAssertEqual(ratios, [0.5, 0.5])
        XCTAssertEqual(focus, c.id)  // neighbor at min(1, count-1) == index 1
        XCTAssertEqual(children.count, 2)
    }

    func testCloseLastSurfaceReturnsNil() {
        let a = term(); let root = leaf(a)
        let (out, focus) = LayoutTree.closeSurface(root, surface: a.id)
        XCTAssertNil(out)
        XCTAssertNil(focus)
    }

    func testDirectionMapping() {
        XCTAssertEqual(LayoutTree.orientationAndSide(for: .right).0, .horizontal)
        XCTAssertEqual(LayoutTree.orientationAndSide(for: .right).1, .after)
        XCTAssertEqual(LayoutTree.orientationAndSide(for: .left).1, .before)
        XCTAssertEqual(LayoutTree.orientationAndSide(for: .down).0, .vertical)
        XCTAssertEqual(LayoutTree.orientationAndSide(for: .down).1, .after)
        XCTAssertEqual(LayoutTree.orientationAndSide(for: .up).1, .before)
    }

    // MARK: - move

    func testMoveRightBetweenTwoLeaves() {
        let a = term(); let b = term()
        let root = LayoutNode.split(
            orientation: .vertical, children: [leaf(a), leaf(b)], ratios: [0.5, 0.5])
        // Move a beside b on its right: b's slot becomes a horizontal [b, a].
        guard let (out, focus) = LayoutTree.move(
            root, surfaceID: a.id, toTarget: b.id, direction: .right) else { return XCTFail() }
        guard case .split(let o, let children, _) = out else { return XCTFail() }
        XCTAssertEqual(o, .horizontal)
        XCTAssertEqual(LayoutTree.surfaceIDs(out), [b.id, a.id])
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(focus, a.id)  // moved surface keeps focus and its id
    }

    func testMoveLeftBetweenTwoLeaves() {
        let a = term(); let b = term()
        let root = LayoutNode.split(
            orientation: .vertical, children: [leaf(a), leaf(b)], ratios: [0.5, 0.5])
        guard let (out, focus) = LayoutTree.move(
            root, surfaceID: a.id, toTarget: b.id, direction: .left) else { return XCTFail() }
        guard case .split(let o, _, _) = out else { return XCTFail() }
        XCTAssertEqual(o, .horizontal)
        XCTAssertEqual(LayoutTree.surfaceIDs(out), [a.id, b.id])
        XCTAssertEqual(focus, a.id)
    }

    func testMoveDownBetweenTwoLeaves() {
        let a = term(); let b = term()
        let root = LayoutNode.split(
            orientation: .horizontal, children: [leaf(a), leaf(b)], ratios: [0.5, 0.5])
        guard let (out, focus) = LayoutTree.move(
            root, surfaceID: a.id, toTarget: b.id, direction: .down) else { return XCTFail() }
        guard case .split(let o, _, _) = out else { return XCTFail() }
        XCTAssertEqual(o, .vertical)
        XCTAssertEqual(LayoutTree.surfaceIDs(out), [b.id, a.id])
        XCTAssertEqual(focus, a.id)
    }

    func testMoveUpBetweenTwoLeaves() {
        let a = term(); let b = term()
        let root = LayoutNode.split(
            orientation: .horizontal, children: [leaf(a), leaf(b)], ratios: [0.5, 0.5])
        guard let (out, focus) = LayoutTree.move(
            root, surfaceID: a.id, toTarget: b.id, direction: .up) else { return XCTFail() }
        guard case .split(let o, _, _) = out else { return XCTFail() }
        XCTAssertEqual(o, .vertical)
        XCTAssertEqual(LayoutTree.surfaceIDs(out), [a.id, b.id])
        XCTAssertEqual(focus, a.id)
    }

    func testMovePreservesSourceSurfaceValueVerbatim() {
        // A non-terminal surface with a distinctive kind, so we can prove the
        // exact value (not just the id) is reinserted unchanged.
        let a = Surface(kind: .browser(url: URL(string: "http://example.com")!))
        let b = term()
        let root = LayoutNode.split(
            orientation: .horizontal, children: [leaf(a), leaf(b)], ratios: [0.5, 0.5])
        guard let (out, _) = LayoutTree.move(
            root, surfaceID: a.id, toTarget: b.id, direction: .right) else { return XCTFail() }
        var moved: Surface?
        func find(_ node: LayoutNode) {
            switch node {
            case .leaf(let s): if s.id == a.id { moved = s }
            case .split(_, let children, _): children.forEach(find)
            }
        }
        find(out)
        XCTAssertEqual(moved, a)  // id and kind both preserved verbatim
    }

    func testMoveCollapsesNestedTwoChildSplitOnRemoval() {
        // a lives in a nested split with a single sibling s; removing a should
        // collapse that split to just s, then a is reinserted beside target c.
        let a = term(); let s = term(); let c = term()
        let nested = LayoutNode.split(
            orientation: .vertical, children: [leaf(a), leaf(s)], ratios: [0.5, 0.5])
        let root = LayoutNode.split(
            orientation: .horizontal, children: [nested, leaf(c)], ratios: [0.5, 0.5])
        guard let (out, focus) = LayoutTree.move(
            root, surfaceID: a.id, toTarget: c.id, direction: .right) else { return XCTFail() }
        // Root stays horizontal; the nested split collapsed to leaf(s); c gained
        // a as a flat sibling on its right.
        guard case .split(let o, let children, _) = out else { return XCTFail() }
        XCTAssertEqual(o, .horizontal)
        XCTAssertEqual(LayoutTree.surfaceIDs(out), [s.id, c.id, a.id])
        XCTAssertEqual(children.count, 3)  // s, c, a all flat under the root
        XCTAssertEqual(focus, a.id)
    }

    func testMoveWithinNarySameOrientationInsertsFlat() {
        let a = term(); let b = term(); let c = term()
        let root = LayoutNode.split(
            orientation: .horizontal, children: [leaf(a), leaf(b), leaf(c)],
            ratios: [0.2, 0.3, 0.5])
        // Move a to c's right: a removed from front, reinserted flat after c.
        guard let (out, _) = LayoutTree.move(
            root, surfaceID: a.id, toTarget: c.id, direction: .right) else { return XCTFail() }
        guard case .split(let o, let children, _) = out else { return XCTFail() }
        XCTAssertEqual(o, .horizontal)
        XCTAssertEqual(children.count, 3)  // still flat, not nested
        XCTAssertEqual(LayoutTree.surfaceIDs(out), [b.id, c.id, a.id])
    }

    func testMoveReEvensRatios() {
        let a = term(); let b = term(); let c = term()
        let root = LayoutNode.split(
            orientation: .horizontal, children: [leaf(a), leaf(b), leaf(c)],
            ratios: [0.2, 0.3, 0.5])
        guard let (out, _) = LayoutTree.move(
            root, surfaceID: a.id, toTarget: c.id, direction: .right) else { return XCTFail() }
        guard case .split(_, _, let ratios) = out else { return XCTFail() }
        XCTAssertEqual(ratios, [1.0 / 3, 1.0 / 3, 1.0 / 3])
    }

    func testMoveSourceEqualsTargetIsNil() {
        let a = term(); let b = term()
        let root = LayoutNode.split(
            orientation: .horizontal, children: [leaf(a), leaf(b)], ratios: [0.5, 0.5])
        XCTAssertNil(LayoutTree.move(root, surfaceID: a.id, toTarget: a.id, direction: .right))
    }

    func testMoveUnknownSourceIsNil() {
        let a = term(); let b = term()
        let root = LayoutNode.split(
            orientation: .horizontal, children: [leaf(a), leaf(b)], ratios: [0.5, 0.5])
        XCTAssertNil(LayoutTree.move(root, surfaceID: UUID(), toTarget: b.id, direction: .right))
    }

    func testMoveUnknownTargetIsNil() {
        let a = term(); let b = term()
        let root = LayoutNode.split(
            orientation: .horizontal, children: [leaf(a), leaf(b)], ratios: [0.5, 0.5])
        XCTAssertNil(LayoutTree.move(root, surfaceID: a.id, toTarget: UUID(), direction: .right))
    }

    // MARK: - dropZone

    func testDropZoneNearestEdge() {
        let size = CGSize(width: 100, height: 100)
        XCTAssertEqual(LayoutTree.dropZone(at: CGPoint(x: 10, y: 50), in: size), .left)
        XCTAssertEqual(LayoutTree.dropZone(at: CGPoint(x: 90, y: 50), in: size), .right)
        XCTAssertEqual(LayoutTree.dropZone(at: CGPoint(x: 50, y: 10), in: size), .top)
        XCTAssertEqual(LayoutTree.dropZone(at: CGPoint(x: 50, y: 90), in: size), .bottom)
    }

    func testDropZoneCenterTieBreaksToLeft() {
        let size = CGSize(width: 100, height: 100)
        // All four distances equal 0.5; tie-break order picks .left first.
        XCTAssertEqual(LayoutTree.dropZone(at: CGPoint(x: 50, y: 50), in: size), .left)
    }

    func testDropZoneDiagonalTieBreaks() {
        let size = CGSize(width: 100, height: 100)
        // Top-left diagonal: left == top == 0.2; .left wins over .top.
        XCTAssertEqual(LayoutTree.dropZone(at: CGPoint(x: 20, y: 20), in: size), .left)
        // Top-right diagonal: right == top == 0.2; .right wins over .top.
        XCTAssertEqual(LayoutTree.dropZone(at: CGPoint(x: 80, y: 20), in: size), .right)
        // Bottom-right diagonal: right == bottom == 0.2; .right wins over .bottom.
        XCTAssertEqual(LayoutTree.dropZone(at: CGPoint(x: 80, y: 80), in: size), .right)
    }

    func testDropZoneZeroSizeDefaultsToLeft() {
        XCTAssertEqual(LayoutTree.dropZone(at: .zero, in: .zero), .left)
        XCTAssertEqual(
            LayoutTree.dropZone(at: CGPoint(x: 5, y: 5), in: CGSize(width: 0, height: 10)), .left)
    }

    func testDropZoneDirectionMapping() {
        XCTAssertEqual(LayoutTree.DropZone.top.direction, .up)
        XCTAssertEqual(LayoutTree.DropZone.bottom.direction, .down)
        XCTAssertEqual(LayoutTree.DropZone.left.direction, .left)
        XCTAssertEqual(LayoutTree.DropZone.right.direction, .right)
    }
}
