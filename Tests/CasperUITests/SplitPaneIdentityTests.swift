import CasperCore
import Foundation
import XCTest

/// Pins the drag-relocate case that forces `SplitContainerView` to derive its
/// pane identities — each child's surface-id array — from `children` on the very
/// pass that renders them.
///
/// A reorder slips past every cheaper guard. `LayoutTree.move` removes the pane
/// and reinserts it, so the child count does not move and the re-evened ratios
/// come back identical — neither a count comparison nor `.onChange(of: ratios)`
/// sees anything happen. An identity list copied into `@State` and refreshed from
/// `.onChange` is therefore refreshed only *after* the body that has already read
/// it, and that body renders each pane's identity against a neighbour's content:
/// the shared-`NSView` re-parenting churn that leaves a pane blank (see the
/// `persistent-nsview-host-sharing` note). Hence the inline derivation. What the
/// test below covers is the move itself, not how the view stores anything: the
/// identities `ForEach` is keyed by live inside `body`, which no test can read
/// back.
@MainActor
final class SplitPaneIdentityTests: XCTestCase {
    /// Dropping the last pane onto the first one's left edge reorders the siblings
    /// while leaving both cheaper signals untouched — the reason pane identity has
    /// to be read from `children` itself.
    func testDropLeftOfTheFirstPaneReordersSiblingsWithoutTouchingCountOrRatios() throws {
        let a = Surface.terminal(cwd: "/wt")
        let b = Surface.terminal(cwd: "/wt")
        let c = Surface.terminal(cwd: "/wt")
        let before = LayoutNode.split(
            orientation: .horizontal, children: [.leaf(a), .leaf(b), .leaf(c)],
            ratios: LayoutNode.evenRatios(3))

        // Drop C on A's left edge: [A, B, C] becomes [C, A, B].
        let (after, _) = try XCTUnwrap(
            LayoutTree.move(before, surfaceID: c.id, toTarget: a.id, direction: .left))

        let old = try XCTUnwrap(splitParts(of: before))
        let new = try XCTUnwrap(splitParts(of: after))
        XCTAssertEqual(new.children.count, old.children.count, "a count guard cannot see this move")
        XCTAssertEqual(new.ratios, old.ratios, "`.onChange(of: ratios)` cannot see this move either")
        XCTAssertEqual(paneIdentities(of: new.children), [[c.id], [a.id], [b.id]])
        XCTAssertNotEqual(
            paneIdentities(of: new.children), paneIdentities(of: old.children),
            "the pane identities must change, or this proves nothing")
    }

    // MARK: - Helpers

    private func splitParts(
        of node: LayoutNode
    ) -> (orientation: LayoutNode.Orientation, children: [LayoutNode], ratios: [Double])? {
        guard case .split(let orientation, let children, let ratios) = node else { return nil }
        return (orientation, children, ratios)
    }

    /// The identity `SplitContainerView` keys each pane by: the surface ids in that
    /// child's subtree.
    private func paneIdentities(of children: [LayoutNode]) -> [[UUID]] {
        children.map { LayoutTree.surfaceIDs($0) }
    }
}
