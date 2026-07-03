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

    func testMapSurfaceReplacesByID() {
        let a = term()
        let root = LayoutNode.leaf(a)
        let out = LayoutTree.mapSurface(root, id: a.id) { _ in
            Surface(id: a.id, kind: .browser(url: URL(string: "http://x")!))
        }
        guard case .leaf(let s) = out, case .browser = s.kind else { return XCTFail() }
        XCTAssertEqual(s.id, a.id)  // id preserved
    }

    func testDirectionMapping() {
        XCTAssertEqual(LayoutTree.orientationAndSide(for: .right).0, .horizontal)
        XCTAssertEqual(LayoutTree.orientationAndSide(for: .right).1, .after)
        XCTAssertEqual(LayoutTree.orientationAndSide(for: .left).1, .before)
        XCTAssertEqual(LayoutTree.orientationAndSide(for: .down).0, .vertical)
        XCTAssertEqual(LayoutTree.orientationAndSide(for: .down).1, .after)
        XCTAssertEqual(LayoutTree.orientationAndSide(for: .up).1, .before)
    }
}
