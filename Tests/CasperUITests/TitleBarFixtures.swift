import AppKit
import CasperCore
import SwiftUI
import XCTest
@testable import CasperUI

/// What one hosted layout of the production title-bar row measured.
struct TitleBarRowLayout {
    /// The width the host reported to its parent.
    ///
    /// Of no use as a measurement of what the row DREW: the row's body ends in
    /// `.frame(width:)`, which reports exactly the width it was handed whatever nests
    /// inside it (see the `fixed-frame-swallows-inner-padding` note). The three
    /// channels below are what carry the row's own layout.
    let reported: CGFloat

    /// The width the badge slot took — `0` on the rungs that drop the badge whole, and
    /// `-1` if the row never laid a badge slot out at all.
    let badge: CGFloat

    /// The width the chip ladder took, which is what says which tier it settled on.
    /// `-1` if the row never laid the chips out at all.
    let ladder: CGFloat

    /// Every rung the row named, empty unless the layout was asked to report them.
    let rungs: [TitleBarRung]
}

/// Fixtures for the title-bar row, shared by the two suites that measure it:
/// `WorkspaceToolbarActionsTests` (the chip ladder) and `WorkspaceTitleBarRungTests`
/// (the rung the row reports).
extension XCTestCase {
    /// A branch name long enough that the title group cannot fit beside a full row of
    /// chips at the widths those suites sweep.
    static let titleBarBranch = "feature/replay-to-repair"

    /// A model and a linked workspace that records a base branch (so the Merge chip
    /// shows) and carries two named commands (so the Run Script chip shows).
    @MainActor
    func makeTitleBarModelAndWorkspace(
        inspector: InspectorState = InspectorState()
    ) -> (AppModel, Workspace) {
        let workspace = Workspace(
            name: "feature", worktreePath: "/wt", branch: Self.titleBarBranch,
            portBase: 40000, layout: .leaf(Surface.terminal(cwd: "/wt")),
            kind: .linked, baseBranch: "main", inspector: inspector)
        let space = Space(
            name: "casper", folderPath: "/repo", isGitRepo: true, workspaces: [workspace])
        let model = makeModel(spaces: [space], selecting: workspace.id)
        model.namedCommandsCache[workspace.id] = [
            RepoNamedCommand(name: "build", command: "make build"),
            RepoNamedCommand(name: "test", command: "make test"),
        ]
        return (model, workspace)
    }

    /// Hosts the production row at `width` and returns what that layout measured.
    ///
    /// The definite frame is what drives the row's ladder: a toolbar item proposes
    /// nothing downward, so an unframed row picks its widest rung whatever budget it
    /// is given (see the `toolbar-item-ignores-max-width` note).
    @MainActor
    func hostTitleBarRow(
        width: CGFloat, diff: (insertions: Int, deletions: Int)? = (12, 3),
        inspector: InspectorState = InspectorState(), reportingRung: Bool = false
    ) -> TitleBarRowLayout {
        let (model, workspace) = makeTitleBarModelAndWorkspace(inspector: inspector)
        var badge: CGFloat = -1
        var ladder: CGFloat = -1
        var rungs: [TitleBarRung] = []
        let row = WorkspaceTitleBarRow(
            model: model, workspace: workspace, diff: diff, width: width,
            onBadgeWidth: { badge = $0 }, onChipsWidth: { ladder = $0 })
            .reportingRung(reportingRung ? { rungs.append($0) } : nil)
        let host = NSHostingView(rootView: row)
        host.frame = NSRect(x: 0, y: 0, width: width, height: TitleCapsuleMetrics.height)
        host.layoutSubtreeIfNeeded()
        return TitleBarRowLayout(
            reported: host.fittingSize.width, badge: badge, ladder: ladder, rungs: rungs)
    }
}
