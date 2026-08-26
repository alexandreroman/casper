import CasperCore
import SwiftUI
import XCTest

@testable import CasperUI

/// Pins what `WorkspaceDetailView` feeds the pane tree: every view below it is
/// built from the workspace's id and layout only, never from the `Workspace`
/// value. A workspace also carries the transient agent fields (state, todos,
/// pending notification, info Markdown), which an agent tick rewrites while the
/// panes render nothing of them — so a workspace stored in a pane view would hand
/// SwiftUI a changed input on every tick and defeat any pruning of the subtree.
@MainActor
final class PaneTreeInputsTests: XCTestCase {
    private func makeModel() -> AppModel {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("casper-test-\(UUID().uuidString).json")
        let workspace = Workspace(
            name: "main", worktreePath: "/tmp/primary", branch: "main",
            portBase: 42000, layout: Self.twoPaneLayout)
        let space = Space(name: "main", folderPath: "/tmp", isGitRepo: true, workspaces: [workspace])
        let session = Session(spaces: [space], selectedWorkspaceID: workspace.id)
        return AppModel(sessionStore: SessionStore(fileURL: url), session: session)
    }

    private static let twoPaneLayout = LayoutNode.split(
        orientation: .horizontal,
        children: [
            .leaf(Surface.terminal(cwd: "/tmp/primary")),
            .leaf(Surface.terminal(cwd: "/tmp/primary")),
        ],
        ratios: LayoutNode.evenRatios(2))

    /// The model side of the contract: a detected agent state rewrites the workspace
    /// value, and leaves both things the pane tree is built from untouched.
    func testAgentTickChangesTheWorkspaceButNotItsIdOrLayout() {
        let model = makeModel()
        let before = model.spaces[0].workspaces[0]

        model.setDetectedAgentState(.working, for: before.id)

        let after = model.spaces[0].workspaces[0]
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(before.id, after.id)
        XCTAssertEqual(before.layout, after.layout)
    }

    /// The view side: rebuilding the pane tree's three views from the ticked
    /// workspace yields the same stored properties, which is what lets SwiftUI skip
    /// their bodies.
    func testAgentTickLeavesThePaneViewsStoredPropertiesUnchanged() throws {
        let model = makeModel()
        let before = model.spaces[0].workspaces[0]

        model.setDetectedAgentState(.working, for: before.id)

        let after = model.spaces[0].workspaces[0]
        XCTAssertNotEqual(before, after, "the tick must change the workspace, or this proves nothing")

        assertStoredPropertiesEqual(node(for: before, model: model), node(for: after, model: model))
        assertStoredPropertiesEqual(
            try XCTUnwrap(split(for: before, model: model)),
            try XCTUnwrap(split(for: after, model: model)))
        assertStoredPropertiesEqual(
            try XCTUnwrap(pane(for: before, model: model)),
            try XCTUnwrap(pane(for: after, model: model)))
    }

    /// Negative control for the test above: a view shaped like the pane views but
    /// holding a `Workspace` must be reported as changed by the very same
    /// comparison, so passing means the properties really are stable rather than
    /// the comparison being blind to them.
    func testTheComparisonCatchesAStoredWorkspace() {
        let model = makeModel()
        let before = model.spaces[0].workspaces[0]

        model.setDetectedAgentState(.working, for: before.id)

        let after = model.spaces[0].workspaces[0]
        XCTAssertEqual(
            mismatchedStoredProperties(
                WorkspaceHoldingView(model: model, workspace: before),
                WorkspaceHoldingView(model: model, workspace: after)),
            ["workspace"])
    }

    /// Stands in for a pane view that stores the whole `Workspace` — the shape this
    /// change removed, kept here only as the negative control's subject.
    private struct WorkspaceHoldingView {
        let model: AppModel
        let workspace: Workspace
    }

    func testHasMultiplePanesIsTrueExactlyForASplitRoot() {
        XCTAssertFalse(WorkspaceDetailView.hasMultiplePanes(in: .leaf(Surface.terminal(cwd: "/tmp"))))
        XCTAssertTrue(WorkspaceDetailView.hasMultiplePanes(in: Self.twoPaneLayout))
    }

    // MARK: - Helpers

    /// The three views exactly as `WorkspaceDetailView` and its children build them.

    private func node(for workspace: Workspace, model: AppModel) -> LayoutNodeView {
        LayoutNodeView(
            model: model, workspaceID: workspace.id, node: workspace.layout,
            canDragPanes: WorkspaceDetailView.hasMultiplePanes(in: workspace.layout))
    }

    private func split(for workspace: Workspace, model: AppModel) -> SplitContainerView? {
        guard case .split(let orientation, let children, let ratios) = workspace.layout else { return nil }
        return SplitContainerView(
            model: model, workspaceID: workspace.id,
            path: [], orientation: orientation, children: children, ratios: ratios)
    }

    private func pane(for workspace: Workspace, model: AppModel) -> SurfaceHostView? {
        guard let surface = LayoutTree.surfaces(workspace.layout).first else { return nil }
        return SurfaceHostView(
            model: model, workspaceID: workspace.id, surface: surface,
            canDrag: WorkspaceDetailView.hasMultiplePanes(in: workspace.layout))
    }

    private func assertStoredPropertiesEqual<V>(
        _ lhs: V, _ rhs: V, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            mismatchedStoredProperties(lhs, rhs), [],
            "\(V.self) stored properties differ across an agent tick",
            file: file, line: line)
    }

    /// The names of the stored properties that differ between two values of the same
    /// type. Reflection rather than a hand-written list of properties, so a
    /// `Workspace` threaded back into one of these views fails the test instead of
    /// silently re-coupling the pane tree to the agent fields. Non-`Equatable`
    /// properties are skipped — the `AppModel` reference and SwiftUI's `@State`
    /// storage — which is no hole for the case this guards: `Workspace` is
    /// `Equatable`, as `testTheComparisonCatchesAStoredWorkspace` pins.
    private func mismatchedStoredProperties<V>(_ lhs: V, _ rhs: V) -> [String] {
        zip(Mirror(reflecting: lhs).children, Mirror(reflecting: rhs).children)
            .filter { leftChild, rightChild in
                guard let value = leftChild.value as? any Equatable else { return false }
                return !isEqual(value, rightChild.value)
            }
            .map { leftChild, _ in leftChild.label ?? "?" }
    }

    private func isEqual<T: Equatable>(_ lhs: T, _ rhs: Any) -> Bool {
        guard let rhs = rhs as? T else { return false }
        return lhs == rhs
    }
}
