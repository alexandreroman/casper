import XCTest
import CasperCore
@testable import CasperUI

@MainActor
final class MenuStateTests: XCTestCase {
    private func makeModel(selecting kind: WorkspaceKind, baseBranch: String? = "main") -> AppModel {
        let primary = Workspace(
            name: "main", worktreePath: "/tmp/primary", branch: "main",
            portBase: 42000, layout: .leaf(Surface.terminal(cwd: "/tmp/primary")))
        let linked = Workspace(
            name: "feature", worktreePath: "/tmp/feature", branch: "feature",
            portBase: 42010, layout: .leaf(Surface.terminal(cwd: "/tmp/feature")),
            kind: .linked, baseBranch: baseBranch)
        let space = Space(name: "main", folderPath: "/tmp", isGitRepo: true, workspaces: [primary, linked])
        let selectedID = kind == .primary ? primary.id : linked.id
        return makeModel(spaces: [space], selecting: selectedID)
    }

    func testCloseAndDeleteEnabledForLinkedWorkspaceWithBaseBranch() {
        let model = makeModel(selecting: .linked, baseBranch: "main")
        XCTAssertTrue(model.canCloseSelectedWorkspace)
        XCTAssertTrue(model.canDeleteSelectedWorkspace)
    }

    func testCloseDisabledWhenLinkedWorkspaceHasNoBaseBranch() {
        let model = makeModel(selecting: .linked, baseBranch: nil)
        XCTAssertFalse(model.canCloseSelectedWorkspace)
        XCTAssertTrue(model.canDeleteSelectedWorkspace)
    }

    func testCloseAndDeleteDisabledForPrimaryWorkspace() {
        let model = makeModel(selecting: .primary)
        XCTAssertFalse(model.canCloseSelectedWorkspace)
        XCTAssertFalse(model.canDeleteSelectedWorkspace)
    }

    func testHasSelectedWorkspaceReflectsSelection() {
        let model = makeModel(selecting: .linked)
        XCTAssertTrue(model.hasSelectedWorkspace)
        model.selectedWorkspaceID = nil
        XCTAssertFalse(model.hasSelectedWorkspace)
    }

    /// The always-enabled Split menu items delegate to `applyNewSplit`, which must
    /// no-op unless a terminal is focused: with nothing focused at all, and with a
    /// focused non-layout surface (the Inspector browser, which lives outside the
    /// layout tree), the layout stays exactly as it was.
    func testApplyNewSplitNoOpsWhenNoTerminalFocused() {
        let model = makeModel(selecting: .linked)
        let workspace = model.spaces[0].workspaces[0]
        let layoutBefore = workspace.layout

        model.focusedSurfaceID = nil
        model.applyNewSplit(.right)
        XCTAssertEqual(model.spaces[0].workspaces[0].layout, layoutBefore, "nothing focused")

        model.focusedSurfaceID = workspace.inspector.browser.id
        model.applyNewSplit(.right)
        XCTAssertEqual(
            model.spaces[0].workspaces[0].layout, layoutBefore, "Inspector browser focused")
    }

    /// A focused terminal pane splits: `applyNewSplit` adds a surface to the layout.
    func testApplyNewSplitSplitsFocusedTerminal() {
        let model = makeModel(selecting: .linked)
        let layoutSurfaceID = LayoutTree.surfaceIDs(model.spaces[0].workspaces[0].layout).first!
        XCTAssertEqual(LayoutTree.surfaceIDs(model.spaces[0].workspaces[0].layout).count, 1)

        model.focusedSurfaceID = layoutSurfaceID
        model.applyNewSplit(.right)

        XCTAssertEqual(LayoutTree.surfaceIDs(model.spaces[0].workspaces[0].layout).count, 2)
    }

    func testCanCreateWorkspaceIsFalseWithNoSpaces() {
        XCTAssertFalse(makeModel().canCreateWorkspace)
    }

    /// The edge-triggered `menu…` flags the menu body observes must track the
    /// computed enable-state properties as raw inputs change. This guards against
    /// `didSet` silently not firing (which would leave the menu stuck on stale
    /// enable-state) — the whole point of the flags is that they stay in sync.
    func testMenuFlagsTrackComputedPropertiesOnStateChange() {
        let model = makeModel(selecting: .linked, baseBranch: "main")

        // Seeded at init from the restored linked selection.
        XCTAssertEqual(model.menuHasSelectedWorkspace, model.hasSelectedWorkspace)
        XCTAssertEqual(model.menuCanDeleteSelectedWorkspace, model.canDeleteSelectedWorkspace)
        XCTAssertEqual(model.menuCanCloseSelectedWorkspace, model.canCloseSelectedWorkspace)
        XCTAssertTrue(model.menuCanDeleteSelectedWorkspace)

        // Clearing the selection flips the workspace-scoped flags off.
        model.selectedWorkspaceID = nil
        XCTAssertEqual(model.menuHasSelectedWorkspace, model.hasSelectedWorkspace)
        XCTAssertEqual(model.menuCanDeleteSelectedWorkspace, model.canDeleteSelectedWorkspace)
        XCTAssertFalse(model.menuHasSelectedWorkspace)
        XCTAssertFalse(model.menuCanDeleteSelectedWorkspace)
    }
}
