import Foundation
import SwiftUI
import XCTest
import CasperCore
@testable import CasperUI

/// Layout tests for the title-bar row and its four-tier degradation ladder.
///
/// The failure they guard against is what happens when the row does not give way:
/// AppKit sizes a toolbar item to its content's ideal width and will not shrink it,
/// so a row that stays wide is pushed into the overflow chevron whole — where these
/// custom chips render without their capsule chrome and the segmented control clips
/// to a lone glyph. The ladder only prevents that if each tier really is narrower
/// than the one above it AND a constrained row really selects a narrower tier —
/// both pure geometry, so both are measurable headlessly (see the
/// `headless-swiftui-layout-tests` note).
///
/// `AppModel.availableEditors` is machine-dependent (it detects installed app
/// bundles), so every assertion here holds whether or not the Editor chip is
/// present: the fixture seeds Merge and Run Script, and nothing asserts an
/// absolute width.
@MainActor
final class WorkspaceToolbarActionsTests: XCTestCase {
    /// A branch name long enough that the title group cannot fit beside a full row
    /// of chips at the widths tested below.
    private static let branch = "feature/replay-to-repair"

    /// Each tier must be strictly narrower than the one above it. A body that
    /// merely reorders the chips, or forgets to pin `.iconOnly` at `.compact` (the
    /// toolbar environment's default is not to be trusted — see the
    /// `toolbar-label-style` note), flunks this: the tiers would measure alike and
    /// the ladder would be cosmetic.
    func testEachTierIsStrictlyNarrowerThanTheOneAboveIt() {
        let actions = makeActions()

        let full = width(actions.row(.full))
        let mergeGlyph = width(actions.row(.mergeGlyph))
        let folded = width(actions.row(.folded))
        let minimal = width(actions.row(.minimal))

        XCTAssertGreaterThan(
            full, mergeGlyph, "moving Run and Editor into the menu freed no width")
        XCTAssertGreaterThan(
            mergeGlyph, folded, "folding Merge into the menu too freed no width")
        XCTAssertGreaterThan(minimal, 0, "the last tier must still draw its chip")
        XCTAssertGreaterThan(folded, minimal, "dropping the segmented control freed no width")
    }

    /// The inspector tab selector rides inside every tier but the last, which is
    /// what keeps it out of AppKit's overflow popover. A refactor that quietly
    /// dropped it from a tier flunks this.
    func testEveryTierButTheLastCarriesTheInspectorSelector() {
        let actions = makeActions()
        let ellipsisChip = width(actions.row(.minimal))

        for density in [WorkspaceToolbarActions.Density.full, .mergeGlyph, .folded] {
            XCTAssertGreaterThanOrEqual(
                width(actions.row(density)), InspectorTabSelector.intrinsicWidth + ellipsisChip,
                "density \(density)")
        }
    }

    /// Every tier stays one row of the shared capsule height. A body whose chips
    /// wrap or stack instead of shrinking flunks this — the failure mode the
    /// `toolbar-group-truncation` note describes, where the title bar is pushed
    /// open instead of the content giving way.
    func testEveryTierLaysOutAtTheSharedCapsuleHeight() {
        let actions = makeActions()

        for density in WorkspaceToolbarActions.Density.allCases {
            XCTAssertEqual(
                size(actions.row(density)).height, TitleCapsuleMetrics.height, accuracy: 0.5,
                "density \(density)")
        }
    }

    /// Every glyph chip on the bar measures exactly the `⋯` chip, which is the
    /// reference dimension for the set. `.mergeGlyph` is the tier that draws them:
    /// the Merge glyph, the `⋯` chip and the two selector segments, with a gap before
    /// each. Predicting that row from the shared constant pins all four at once.
    func testEveryGlyphChipMeasuresTheEllipsisChip() {
        let actions = makeActions()

        XCTAssertEqual(
            width(actions.row(.minimal)), TitleCapsuleMetrics.glyphChipWidth, accuracy: 0.5,
            "the reference chip is not one glyph chip wide")

        let expected = 2 * (TitleCapsuleMetrics.glyphChipWidth + WorkspaceDetailView.chipGap)
            + InspectorTabSelector.intrinsicWidth
        XCTAssertEqual(
            width(actions.row(.mergeGlyph)), expected, accuracy: 0.5,
            "a glyph chip is not the reference width")
    }

    /// The Merge chip must not change size when Option swaps it to Delete: the swap
    /// happens under a stationary pointer, and a chip that resizes there reads as a
    /// different control appearing rather than the same one relabelled.
    func testMergeAndDeleteChipsMeasureTheSame() {
        let (model, workspace) = makeModelAndWorkspace()
        let merge = width(mergeRow(model: model, workspace: workspace))
        model.optionKeyHeld = true
        let delete = width(mergeRow(model: model, workspace: workspace))

        XCTAssertEqual(merge, delete, accuracy: 0.5)
        XCTAssertEqual(merge, TitleCapsuleMetrics.glyphChipWidth, accuracy: 0.5)
    }

    /// Proves the equalities above have teeth — the symbols really do measure
    /// differently, so equal chips can only come from the shared slot — and that the
    /// slot clears the widest of them.
    func testGlyphSlotClearsEverySymbolThatGoesInIt() {
        let symbols = ["ellipsis", "arrow.triangle.merge", "trash", "plusminus", "globe"]
        let widths = symbols.map { symbolWidth($0) }

        XCTAssertGreaterThan(
            Set(widths.map { Int($0.rounded()) }).count, 1,
            "the symbols all measure alike, so equal chips prove nothing")
        for (symbol, glyph) in zip(symbols, widths) {
            XCTAssertLessThanOrEqual(glyph, TitleCapsuleMetrics.glyphSlotWidth, symbol)
        }
    }

    /// Degradation is monotone across the whole usable range: as the row is given
    /// less, no part of it ever gets MORE. Swept in small steps rather than sampled
    /// at chosen widths, because every non-monotonicity this row has had hid between
    /// the samples — a badge that returned at 260 pt, a badge that came back the
    /// moment the chips folded, and a selector that returned at 279 pt when the
    /// title dropped its Space name and freed 90 pt at once. This one assertion
    /// covers all three, and is the reason the elements share a single ordered
    /// ladder rather than degrading independently.
    ///
    /// Measured through the badge and the ladder's own content width: between them
    /// they move on every rung, so a rung that goes backwards moves one of them
    /// backwards too.
    func testDegradationIsMonotoneAcrossTheWholeRange() {
        var previousBadge: CGFloat = -1
        var previousLadder: CGFloat = -1

        for rowWidth in stride(from: CGFloat(900), through: 60, by: -1) {
            let layout = layoutRow(width: rowWidth)
            if previousBadge >= 0 {
                XCTAssertLessThanOrEqual(
                    layout.badge, previousBadge + 0.5,
                    "the badge grew back at \(rowWidth) pt")
                XCTAssertLessThanOrEqual(
                    layout.ladder, previousLadder + 0.5,
                    "the chips grew back at \(rowWidth) pt")
            }
            previousBadge = layout.badge
            previousLadder = layout.ladder
        }

        XCTAssertLessThan(previousLadder, width(makeActions().row(.full)),
                          "the row never degraded at all, so this proves nothing")
    }

    /// The row never reports more than the width it was given — at any width, with
    /// or without a badge, inspector open or shut. This is the invariant the whole
    /// single-item design rests on: AppKit reads that reported width, and anything
    /// larger than the bar is overflowed WHOLE, emptying the title bar. A content
    /// state that cannot compress must clip, never report its way out.
    func testTheRowNeverReportsMoreThanTheWidthItIsGiven() {
        let openOnDiff = InspectorState(collapsed: false, tab: .diff)
        for rowWidth in [900, 600, 460, 380, 300, 200, 120, 60] as [CGFloat] {
            for (label, diff) in [("badge", (12, 3) as (Int, Int)?), ("no badge", nil)] {
                for (state, inspector) in [("shut", InspectorState()), ("open", openOnDiff)] {
                    let reported = layoutRow(
                        width: rowWidth, diff: diff.map { ($0.0, $0.1) }, inspector: inspector
                    ).reported
                    XCTAssertLessThanOrEqual(
                        reported, rowWidth + 0.5, "\(rowWidth) pt, \(label), inspector \(state)")
                }
            }
        }
    }

    /// Opening the inspector must not change what the row reports. The regression:
    /// toggling the diff panel at a narrow window changed the row's CONTENT while
    /// `rowWidth` stood still, so nothing re-measured and the row went into the
    /// chevron for good.
    func testTogglingTheInspectorDoesNotChangeTheReportedWidth() {
        for rowWidth in [600, 380, 300, 200] as [CGFloat] {
            let shut = layoutRow(width: rowWidth, inspector: InspectorState()).reported
            let onDiff = layoutRow(
                width: rowWidth, inspector: InspectorState(collapsed: false, tab: .diff)).reported
            let onBrowser = layoutRow(
                width: rowWidth, inspector: InspectorState(collapsed: false, tab: .browser)).reported

            XCTAssertEqual(onDiff, shut, accuracy: 0.5, "diff panel, \(rowWidth) pt")
            XCTAssertEqual(onBrowser, shut, accuracy: 0.5, "browser panel, \(rowWidth) pt")
        }
    }

    /// The badge is all-or-nothing: at every width it measures either its full ideal
    /// or exactly zero, never something in between. A badge that merely shrank would
    /// render `+3 −`, which is worse than no counter at all.
    func testTheBadgeIsNeverPartiallyRendered() {
        let ideal = layoutRow(width: 2000).badge
        XCTAssertGreaterThan(ideal, 0, "the badge never rendered, so this proves nothing")

        for rowWidth in stride(from: CGFloat(900), through: 100, by: -20) {
            let badge = layoutRow(width: rowWidth).badge
            XCTAssertTrue(
                abs(badge) < 0.5 || abs(badge - ideal) < 0.5,
                "row \(rowWidth) pt rendered a partial badge of \(badge) pt")
        }
    }

    /// The badge is present when there is room and gone when there is not.
    func testTheBadgeDropsOutAsTheRowNarrows() {
        XCTAssertGreaterThan(layoutRow(width: 900).badge, 0, "the badge should survive a wide row")
        XCTAssertEqual(layoutRow(width: 200).badge, 0, accuracy: 0.5, "the badge should be gone")
    }

    /// Degradation runs one way. Once the badge is gone it must not come back as the
    /// row keeps narrowing — which it did when the badge and the chips were ranked by
    /// layout priority alone rather than chosen together: folding the chips freed
    /// room, and the badge reappeared at 260 pt after vanishing at 500 pt.
    func testTheBadgeNeverComesBackAsTheRowNarrows() {
        var badgeWasGone = false
        for rowWidth in stride(from: CGFloat(900), through: 60, by: -20) {
            let badge = layoutRow(width: rowWidth).badge
            if badge < 0.5 {
                badgeWasGone = true
            } else {
                XCTAssertFalse(badgeWasGone, "the badge came back at \(rowWidth) pt")
            }
        }
        XCTAssertTrue(badgeWasGone, "the badge never dropped, so this proves nothing")
    }

    /// The order of sacrifice has teeth: there is a width where the badge is ALREADY
    /// gone while the chips still carry their text. Without it, "the badge goes
    /// first" would be satisfied by a row that simply dropped everything at once —
    /// and a layout-priority mistake (an equal-priority `Spacer` swallowing the
    /// badge's room, say) reads entirely plausible until measured.
    func testTheBadgeGoesBeforeTheChipsLoseTheirText() {
        let titleAndBadge = layoutRow(width: 2000)
        let badgeIdeal = titleAndBadge.badge

        // Wide enough for the title and the full, text-bearing chip row, but not for
        // those plus the badge.
        let rowWidth = titleIdealWidth + WorkspaceDetailView.chipGap + fullChipsWidth
            + badgeIdeal / 2

        let layout = layoutRow(width: rowWidth)
        XCTAssertEqual(layout.badge, 0, accuracy: 0.5, "the badge outlived the chips' text")
        XCTAssertEqual(
            chipsWidth(inRowOf: rowWidth), fullChipsWidth, accuracy: 0.5,
            "the chips gave up their text before the badge gave up its counters")
    }

    // MARK: - Helpers

    /// A row over a linked workspace that records a base branch (so the Merge chip
    /// shows) and carries two named commands (so the Run Script chip shows).
    private func makeModelAndWorkspace(
        inspector: InspectorState = InspectorState()
    ) -> (AppModel, Workspace) {
        let workspace = Workspace(
            name: "feature", worktreePath: "/wt", branch: Self.branch,
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

    private func makeActions() -> WorkspaceToolbarActions {
        let (model, workspace) = makeModelAndWorkspace()
        return WorkspaceToolbarActions(model: model, workspace: workspace, density: .full)
    }

    /// Hosts the production row at `rowWidth` and reports what it measured, plus
    /// the width the badge slot took (0 when the badge was dropped whole).
    private func layoutRow(
        width rowWidth: CGFloat, diff: (insertions: Int, deletions: Int)? = (12, 3),
        inspector: InspectorState = InspectorState()
    ) -> (reported: CGFloat, badge: CGFloat, ladder: CGFloat) {
        let (model, workspace) = makeModelAndWorkspace(inspector: inspector)
        var badge: CGFloat = -1
        var ladder: CGFloat = -1
        let row = WorkspaceTitleBarRow(
            model: model, workspace: workspace, diff: diff, width: rowWidth,
            onBadgeWidth: { badge = $0 }, onChipsWidth: { ladder = $0 })
        let host = NSHostingView(rootView: row)
        host.frame = NSRect(x: 0, y: 0, width: rowWidth, height: TitleCapsuleMetrics.height)
        host.layoutSubtreeIfNeeded()
        return (host.fittingSize.width, badge, ladder)
    }

    /// The chips' own full-width tier, for the ordering assertion below.
    private var fullChipsWidth: CGFloat { width(makeActions().row(.full)) }

    /// The title group's ideal width, measured from the same label the row renders.
    private var titleIdealWidth: CGFloat {
        width(
            WorkspaceTitleLabel(
                isGitRepo: true, spaceName: "casper", branchLabel: Self.branch,
                form: .spaceAndBranch)
                .padding(.leading, 10)
                .padding(.trailing, 6)
                .lineLimit(1))
            + WorkspaceInfoButton.collapsedWidth
    }

    /// The width the chips laid out to inside a row of `rowWidth`, which is what
    /// says which tier they settled on.
    private func chipsWidth(inRowOf rowWidth: CGFloat) -> CGFloat {
        let (model, workspace) = makeModelAndWorkspace()
        var chips = CGRect.zero
        let row = HStack(spacing: 0) {
            Color.clear.frame(width: titleIdealWidth).layoutPriority(2)
            Spacer(minLength: WorkspaceDetailView.chipGap).layoutPriority(-1)
            WorkspaceToolbarActions(model: model, workspace: workspace, density: .full)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .local) } action: { chips = $0 }
        }
        .frame(width: rowWidth, alignment: .leading)
        let host = NSHostingView(rootView: row)
        host.frame = NSRect(x: 0, y: 0, width: rowWidth, height: TitleCapsuleMetrics.height)
        host.layoutSubtreeIfNeeded()
        return chips.width
    }

    /// The Merge chip alone, as the row draws it at `.compact`.
    private func mergeRow(model: AppModel, workspace: Workspace) -> some View {
        MergeToolbarButton(model: model, workspace: workspace, density: .mergeGlyph)
    }

    private func symbolWidth(_ systemImage: String) -> CGFloat {
        width(Image(systemName: systemImage))
    }

    private func width<V: View>(_ view: V) -> CGFloat { size(view).width }

    private func size<V: View>(_ view: V) -> CGSize {
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }
}
