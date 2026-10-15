import Foundation
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
        let space = Space(name: "casper", folderPath: "/tmp", isGitRepo: true, workspaces: [primary, linked])
        let selectedID = kind == .primary ? primary.id : linked.id
        return makeModel(spaces: [space], selecting: selectedID)
    }

    /// Two single-workspace Spaces, "alpha" then "beta", with beta's workspace
    /// selected — so a lookup that just takes the first Space gives the wrong answer.
    private func makeTwoSpaceModel() -> AppModel {
        func space(_ name: String, portBase: Int) -> Space {
            let path = "/tmp/\(name)"
            let primary = Workspace(
                name: name, worktreePath: path, branch: "main",
                portBase: portBase, layout: .leaf(Surface.terminal(cwd: path)))
            return Space(name: name, folderPath: path, isGitRepo: true, workspaces: [primary])
        }
        let alpha = space("alpha", portBase: 42000)
        let beta = space("beta", portBase: 42010)
        return makeModel(spaces: [alpha, beta], selecting: beta.workspaces[0].id)
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

    // MARK: - Workspace menu tools

    /// "Run Script" needs a named command to resolve. The commands live in a cache
    /// outside `spaces`, so its writes must refresh the flag on their own.
    func testRunScriptFlagFollowsTheSelectedWorkspacesNamedCommands() {
        let model = makeModel(selecting: .linked)
        let linkedID = model.spaces[0].workspaces[1].id
        XCTAssertFalse(model.menuCanRunSelectedWorkspaceScript, "no .casper.json, no script to run")

        model.namedCommandsCache[linkedID] = [RepoNamedCommand(name: "run", command: "make run")]
        XCTAssertTrue(model.menuCanRunSelectedWorkspaceScript)

        model.selectedWorkspaceID = model.spaces[0].workspaces[0].id
        XCTAssertFalse(model.menuCanRunSelectedWorkspaceScript, "the primary workspace has no script")

        model.selectedWorkspaceID = linkedID
        XCTAssertTrue(model.menuCanRunSelectedWorkspaceScript)

        model.selectedWorkspaceID = nil
        XCTAssertFalse(model.menuCanRunSelectedWorkspaceScript)
    }

    /// "Open in Editor" is enabled while an editor is detected and a workspace is
    /// selected. The detected list is set directly, since the machine's own is
    /// whatever happens to be installed.
    func testOpenInEditorFlagFollowsTheDetectedEditorsAndTheSelection() {
        let model = makeModel(selecting: .linked)
        XCTAssertFalse(model.menuCanOpenSelectedWorkspaceInEditor, "editors are detected at launch")

        model.debugSetAvailableEditors([.xcode])
        XCTAssertTrue(model.menuCanOpenSelectedWorkspaceInEditor)

        model.selectedWorkspaceID = nil
        XCTAssertFalse(model.menuCanOpenSelectedWorkspaceInEditor, "nothing selected")

        model.selectedWorkspaceID = model.spaces[0].workspaces[1].id
        XCTAssertTrue(model.menuCanOpenSelectedWorkspaceInEditor)

        model.debugSetAvailableEditors([])
        XCTAssertFalse(model.menuCanOpenSelectedWorkspaceInEditor, "no editor to open")
    }

    // MARK: - View menu inspector toggles

    /// The Diff / Browser checkmark follows the selected workspace's visible tab
    /// through every toggle, and reads nil while the panel is collapsed.
    func testInspectorTabFlagTracksTogglesOnTheSelectedWorkspace() {
        let model = makeModel(selecting: .linked)
        let linkedID = model.spaces[0].workspaces[1].id
        XCTAssertNil(model.menuInspectorTab, "the inspector starts collapsed")

        model.toggleInspectorTab(.diff, for: linkedID)
        XCTAssertEqual(model.menuInspectorTab, .diff)
        model.toggleInspectorTab(.browser, for: linkedID)
        XCTAssertEqual(model.menuInspectorTab, .browser)
        model.toggleInspectorTab(.browser, for: linkedID)
        XCTAssertNil(model.menuInspectorTab, "toggling the showing tab collapses the panel")
    }

    /// The checkmark belongs to the selected workspace: another workspace's toggle
    /// leaves it alone, and moving the selection shows that workspace's tab.
    func testInspectorTabFlagFollowsTheSelection() {
        let model = makeModel(selecting: .linked)
        let primaryID = model.spaces[0].workspaces[0].id
        let linkedID = model.spaces[0].workspaces[1].id

        model.toggleInspectorTab(.browser, for: primaryID)
        XCTAssertNil(model.menuInspectorTab, "an unselected workspace's toggle")

        model.selectedWorkspaceID = primaryID
        XCTAssertEqual(model.menuInspectorTab, .browser)

        model.selectedWorkspaceID = linkedID
        XCTAssertNil(model.menuInspectorTab)

        model.selectedWorkspaceID = nil
        XCTAssertNil(model.menuInspectorTab)
    }

    /// The flag is what keeps the menu body from re-asserting the native menu on
    /// `spaces` churn, so a mutation that leaves the visible tab alone — a width
    /// drag here — must not write it at all.
    func testInspectorTabFlagIsNotWrittenWhenTheVisibleTabIsUnchanged() {
        let model = makeModel(selecting: .linked)
        let linkedID = model.spaces[0].workspaces[1].id
        model.toggleInspectorTab(.diff, for: linkedID)

        nonisolated(unsafe) var changed = false
        withObservationTracking {
            _ = model.menuInspectorTab
        } onChange: {
            changed = true
        }
        model.setInspectorWidth(InspectorState.minWidth + 10, for: linkedID)

        XCTAssertFalse(changed, "an unchanged checkmark must not notify the menu body")
    }

    // MARK: - Remove Space…

    /// Confirming removes the Space; cancelling leaves it — and the question names
    /// the Space, not one of its workspaces.
    func testRemoveSpaceConfirmationGatesTheRemoval() {
        let model = makeModel(selecting: .linked)
        let spaceID = model.spaces[0].id
        var askedAbout: [String] = []
        var answers = [false, true]  // cancel, then confirm
        let original = AppModel.confirmRemoveSpace
        defer { AppModel.confirmRemoveSpace = original }
        AppModel.confirmRemoveSpace = { name in
            askedAbout.append(name)
            return answers.removeFirst()
        }

        model.presentRemoveSpaceConfirmation(id: spaceID)
        XCTAssertEqual(model.spaces.count, 1, "cancelling keeps the Space")

        model.presentRemoveSpaceConfirmation(id: spaceID)
        XCTAssertTrue(model.spaces.isEmpty, "confirming removes the Space")
        XCTAssertEqual(askedAbout, ["casper", "casper"])
        XCTAssertNil(model.selectedWorkspaceID)
        XCTAssertFalse(model.menuCanRemoveSelectedSpace, "Remove Space… disables with nothing selected")
    }

    /// The alert is modal, and the Space can go while it is up — through the control
    /// channel, say. Confirming then removes nothing else.
    func testRemoveSpaceConfirmedAfterTheSpaceIsAlreadyGoneChangesNothingElse() {
        let model = makeTwoSpaceModel()
        let alphaID = model.spaces[0].id
        let betaWorkspaceID = model.spaces[1].workspaces[0].id
        let original = AppModel.confirmRemoveSpace
        defer { AppModel.confirmRemoveSpace = original }
        AppModel.confirmRemoveSpace = { _ in
            model.removeSpace(id: alphaID)
            return true
        }

        model.presentRemoveSpaceConfirmation(id: alphaID)

        XCTAssertEqual(model.spaces.map(\.name), ["beta"])
        XCTAssertEqual(model.selectedWorkspaceID, betaWorkspaceID)
    }

    /// The menu-bar item acts on the selected workspace's Space.
    func testSelectedSpaceIsTheSelectedWorkspacesSpace() {
        let model = makeTwoSpaceModel()
        XCTAssertEqual(model.selectedSpace?.name, "beta")
        model.selectedWorkspaceID = model.spaces[0].workspaces[0].id
        XCTAssertEqual(model.selectedSpace?.name, "alpha")
        model.selectedWorkspaceID = nil
        XCTAssertNil(model.selectedSpace)
    }

    /// A close or delete in flight blocks the sidebar behind its progress sheet but not
    /// the menu bar, so Remove Space… disables itself while any workspace of the
    /// selected Space is being closed — and only that Space.
    func testRemoveSpaceIsDisabledWhileOneOfItsWorkspacesIsBeingClosed() {
        let model = makeTwoSpaceModel()
        let alphaWorkspaceID = model.spaces[0].workspaces[0].id
        let betaWorkspaceID = model.spaces[1].workspaces[0].id
        XCTAssertTrue(model.menuCanRemoveSelectedSpace)

        model.closingWorkspaces.insert(alphaWorkspaceID)
        XCTAssertTrue(model.menuCanRemoveSelectedSpace, "another Space's close leaves beta removable")

        model.closingWorkspaces.insert(betaWorkspaceID)
        XCTAssertFalse(model.menuCanRemoveSelectedSpace)

        model.closingWorkspaces.remove(betaWorkspaceID)
        XCTAssertTrue(model.menuCanRemoveSelectedSpace)

        model.selectedWorkspaceID = alphaWorkspaceID
        XCTAssertFalse(model.menuCanRemoveSelectedSpace, "the selection moved onto the closing Space")
    }
}
