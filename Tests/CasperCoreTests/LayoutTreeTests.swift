import XCTest
@testable import CasperCore

final class LayoutTreeTests: XCTestCase {
    private func term(_ tag: String) -> Surface {
        Surface(kind: .terminal(cwd: "/w", command: nil))
    }
    private func group(_ surfaces: [Surface], active: Int = 0) -> LayoutNode {
        .tabGroup(surfaces: surfaces, activeIndex: active)
    }

    func testInsertTabAppendsAndActivates() {
        let a = term("a"); let root = group([a])
        let b = term("b")
        let (out, focus) = LayoutTree.insertTab(root, focused: a.id, surface: b)
        guard case .tabGroup(let s, let active) = out else { return XCTFail() }
        XCTAssertEqual(s.map(\.id), [a.id, b.id])
        XCTAssertEqual(active, 1)
        XCTAssertEqual(focus, b.id)
    }

    func testSplitFromRootTabGroupWrapsInSplit() {
        let a = term("a"); let root = group([a]); let b = term("b")
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
        let a = term("a"); let b = term("b")
        let root = LayoutNode.split(
            orientation: .horizontal, children: [group([a]), group([b])],
            ratios: [0.5, 0.5])
        let c = term("c")
        let (out, _) = LayoutTree.split(
            root, focused: a.id, orientation: .horizontal, side: .after, surface: c)
        guard case .split(_, let children, let ratios) = out else { return XCTFail() }
        XCTAssertEqual(children.count, 3)  // flat, not nested
        XCTAssertEqual(LayoutTree.surfaceIDs(out), [a.id, c.id, b.id])
        XCTAssertEqual(ratios.reduce(0, +), 1.0, accuracy: 1e-9)
    }

    func testSplitDifferentOrientationNests() {
        let a = term("a"); let b = term("b")
        let root = LayoutNode.split(
            orientation: .horizontal, children: [group([a]), group([b])],
            ratios: [0.5, 0.5])
        let c = term("c")
        let (out, _) = LayoutTree.split(
            root, focused: a.id, orientation: .vertical, side: .after, surface: c)
        guard case .split(_, let children, _) = out else { return XCTFail() }
        XCTAssertEqual(children.count, 2)  // a's slot became a nested split
        guard case .split(let innerO, let inner, _) = children[0] else { return XCTFail() }
        XCTAssertEqual(innerO, .vertical)
        XCTAssertEqual(inner.count, 2)
        XCTAssertEqual(LayoutTree.surfaceIDs(out), [a.id, c.id, b.id])
    }

    func testCloseSurfaceInMultiTabAdjustsActive() {
        let a = term("a"); let b = term("b")
        let root = group([a, b], active: 1)  // b active
        let (out, focus) = LayoutTree.closeSurface(root, surface: b.id)
        guard case .tabGroup(let s, let active)? = out else { return XCTFail() }
        XCTAssertEqual(s.map(\.id), [a.id])
        XCTAssertEqual(active, 0)
        XCTAssertEqual(focus, a.id)
    }

    func testCloseSurfaceCollapsesSingleChildSplit() {
        let a = term("a"); let b = term("b")
        let root = LayoutNode.split(
            orientation: .horizontal, children: [group([a]), group([b])],
            ratios: [0.5, 0.5])
        let (out, focus) = LayoutTree.closeSurface(root, surface: b.id)
        guard case .tabGroup(let s, _)? = out else { return XCTFail("expected collapse to tabGroup") }
        XCTAssertEqual(s.map(\.id), [a.id])
        XCTAssertEqual(focus, a.id)
    }

    func testCloseLastSurfaceReturnsNil() {
        let a = term("a"); let root = group([a])
        let (out, focus) = LayoutTree.closeSurface(root, surface: a.id)
        XCTAssertNil(out)
        XCTAssertNil(focus)
    }

    func testActivateSetsActiveIndexOfContainingTabGroup() {
        let a = term("a"); let b = term("b")
        let root = group([a, b])
        let out = LayoutTree.activate(root, surface: b.id)
        guard case .tabGroup(let s, let active) = out else { return XCTFail() }
        XCTAssertEqual(s.map(\.id), [a.id, b.id])
        XCTAssertEqual(active, 1)
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
