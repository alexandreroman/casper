import Foundation
import SwiftUI
import XCTest
import CasperCore
@testable import CasperUI

/// Tests for the rung the title-bar row REPORTS, which is what the passive resize
/// trace logs as `rung=` (see `TitleBarResizeTrace`).
///
/// The trace exists to tell two flickers apart: the whole bar falling into AppKit's
/// overflow chevron, and the chips folding and unfolding while the pointer keeps
/// moving. Only the second one needs the rung, and only if the reported rung is the
/// rung actually on screen — a reporter that named the wrong candidate, or that named
/// every candidate, would turn every trace into a false oscillation. That is pure
/// layout, so it is measurable headlessly (see the `headless-swiftui-layout-tests`
/// note).
///
/// Nothing here asserts which width selects which rung: hosted geometry differs
/// between this machine and the CI runner, and the row's own widths depend on which
/// chips the workspace offers. The assertions are relative — one width against the
/// next, and the reported rung against the badge the same layout drew.
@MainActor
final class WorkspaceTitleBarRungTests: XCTestCase {
    /// A branch name long enough that the title group cannot fit beside a full row of
    /// chips at the widths swept below.
    private static let branch = "feature/replay-to-repair"

    /// Wide enough for every rung to fit, so the ladder must select its first.
    private static let roomyWidth: CGFloat = 2000

    /// Narrower than any rung, so `ViewThatFits` must fall back to its last.
    private static let crampedWidth: CGFloat = 60

    /// Where the point-by-point sweep starts. Every rung is still reachable from here
    /// — the badge survives a 900 pt row — and the band above it holds no transition,
    /// so a wider start would only cost the suite one hosted layout per point.
    private static let sweepWidth: CGFloat = 900

    /// A layout reports the rung it placed and no other. This is the whole basis of
    /// the field: `ViewThatFits` measures every candidate but places one, so a
    /// reporter that spoke for the measured candidates too would name the narrowest
    /// rung at every width and a trace would read as one permanent oscillation.
    func testALayoutReportsExactlyOneRung() {
        for width in [Self.roomyWidth, 900, 600, 400, 200, Self.crampedWidth] as [CGFloat] {
            let reported = layout(width: width).rungs
            XCTAssertFalse(reported.isEmpty, "no rung reported at \(width) pt")
            XCTAssertEqual(
                Set(reported.map(\.label)).count, 1,
                "\(width) pt reported \(Set(reported.map(\.label)).sorted())")
        }
    }

    /// Every reported rung is one the ladder mapping knows. Rung `0` is the mapping's
    /// "combination the row never builds" answer, so it fires exactly when
    /// `WorkspaceTitleBarRow.body` grew a candidate that `TitleBarRung.init` was not
    /// taught — the drift this pins, since the two lists cannot be shared (a
    /// `ViewThatFits` takes each direct child as one candidate).
    func testEveryReportedRungIsOnTheLadder() {
        for width in stride(from: Self.roomyWidth, through: Self.crampedWidth, by: -20) {
            guard let rung = layout(width: width).rungs.last else {
                return XCTFail("no rung reported at \(width) pt")
            }
            XCTAssertGreaterThan(rung.number, 0, "\(width) pt placed an unmapped rung")
        }
    }

    /// The reported rung only ever moves DOWN the ladder as the row is given less —
    /// which is the property a trace of a real drag is read against. A `rung=` that
    /// went back up inside one drag would then be the row's declared width wobbling,
    /// not the reporter's doing.
    ///
    /// Swept 5 pt at a time, because what this pins is that the REPORTER tracks the
    /// ladder — the ladder's own monotonicity is swept point by point over this same
    /// range by `WorkspaceToolbarActionsTests.testDegradationIsMonotoneAcrossTheWholeRange`.
    /// The reported rung is a step function over six rungs and no rung occupies a band
    /// anywhere near 5 pt wide (the narrowest measured here spans 46 pt), so a 5 pt step
    /// cannot straddle a rung and hide a climb-back inside one stride.
    func testTheReportedRungNeverClimbsBackAsTheRowNarrows() {
        var previous = 0
        for width in stride(from: Self.sweepWidth, through: Self.crampedWidth, by: -5) {
            guard let rung = layout(width: width).rungs.last else {
                return XCTFail("no rung reported at \(width) pt")
            }
            XCTAssertGreaterThanOrEqual(
                rung.number, previous,
                "the ladder climbed back to \(rung.label) at \(width) pt")
            previous = rung.number
        }
        XCTAssertGreaterThan(previous, 1, "the ladder never moved, so this proves nothing")
    }

    /// The ends of the ladder: a roomy row places its first rung, badge and all, and a
    /// row narrower than every candidate places its last. Without both ends pinned,
    /// the monotonicity above would be satisfied by a reporter that named one rung
    /// forever.
    func testTheLadderRunsFromItsFirstRungToItsLast() {
        XCTAssertEqual(
            layout(width: Self.roomyWidth).rungs.last?.label,
            "1/spaceAndBranch/badge/full")
        XCTAssertEqual(
            layout(width: Self.crampedWidth).rungs.last?.label,
            "6/branchOnly/noBadge/minimal")
    }

    /// The reported rung agrees with what the same layout drew. The badge is the one
    /// element of a rung an outside observer can measure on its own — it is
    /// all-or-nothing, so its width is a clean yes/no — and a rung claiming a badge
    /// the row did not draw (or the reverse) would mean the reporter is speaking for a
    /// different candidate than the one on screen.
    func testTheReportedRungAgreesWithTheBadgeTheRowDrew() {
        for width in stride(from: Self.roomyWidth, through: Self.crampedWidth, by: -20) {
            let measured = layout(width: width)
            guard let rung = measured.rungs.last else {
                return XCTFail("no rung reported at \(width) pt")
            }
            let drewBadge = measured.badge > 0.5
            XCTAssertEqual(
                rung.label.contains("/badge/"), drewBadge,
                "\(rung.label) disagrees with a badge of \(measured.badge) pt at \(width) pt")
        }
    }

    /// A row that is re-laid-out at a new width reports the rung it moved to. The
    /// reporter therefore does not depend on SwiftUI unmounting the candidates
    /// `ViewThatFits` rejected — which is exactly the case a drag consists of, one
    /// live row re-measured every frame, as opposed to the fresh hosts every other
    /// test here builds.
    func testARelayoutReportsTheRungItMovedTo() {
        var reported: [TitleBarRung] = []
        let host = NSHostingView(
            rootView: row(width: Self.roomyWidth, report: { reported.append($0) }))
        host.frame = NSRect(x: 0, y: 0, width: Self.roomyWidth, height: TitleCapsuleMetrics.height)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(reported.last?.number, 1, "the roomy row did not start on rung 1")

        reported.removeAll()
        host.rootView = row(width: Self.crampedWidth, report: { reported.append($0) })
        host.frame = NSRect(
            x: 0, y: 0, width: Self.crampedWidth, height: TitleCapsuleMetrics.height)
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            reported.last?.number, 6,
            "a re-laid-out row reported \(reported.last?.label ?? "nothing")")
    }

    /// A rung the row moves to WITHOUT its width changing reports itself. This is the
    /// half of the reporter's contract that geometry cannot carry: every rung fills the
    /// row's declared width, so the reporter's own size is the same on all six, and a
    /// rung change driven by content at a standing window (a diff summary arriving, a
    /// script appearing) moves nothing measurable. What delivers the report there is
    /// `ViewThatFits` placing a different child, giving the reporter a fresh identity
    /// and so a first layout — measured here, and it does fire.
    ///
    /// The content change is the diff summary going away, which is one of the real ones
    /// (`WorkspaceDetailView` refreshes it off `model.diffRevision`). Rungs 1 and 2
    /// differ only by the badge, so with no summary to draw rung 1 measures exactly like
    /// rung 2 and the ladder climbs back to it at the very same width.
    func testANewlySelectedRungReportsAtAnUnchangedWidth() {
        let width = widestWidthWithoutTheBadge()
        var reported: [TitleBarRung] = []
        let host = NSHostingView(rootView: row(width: width, report: { reported.append($0) }))
        host.frame = NSRect(x: 0, y: 0, width: width, height: TitleCapsuleMetrics.height)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            reported.last?.number, 2,
            "the badge's own boundary placed \(reported.last?.label ?? "nothing") at \(width) pt")

        // The same host at the same frame: only the summary goes away.
        reported.removeAll()
        host.rootView = row(width: width, diff: nil, report: { reported.append($0) })
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            reported.last?.number, 1,
            "a rung change at an unchanged \(width) pt reported \(reported.last?.label ?? "nothing")")
    }

    /// With no hook the row builds no reporter, which is the state every session that
    /// did not arm a trace runs in. The reporter rides in a `background`, so installing
    /// it must change nothing the row lays out.
    ///
    /// Measured through the BADGE's width rather than the row's own: the row's body ends
    /// in `.frame(width:)`, which reports the width it was handed whatever nests inside
    /// it (see the `fixed-frame-swallows-inner-padding` note), so comparing that would
    /// compare the fixture with itself at every width. The badge sits inside that frame
    /// and its width moves with the rung, which makes it a measurement of what the row
    /// actually did.
    func testTheReporterDoesNotChangeWhatTheRowMeasures() {
        // One point above the badge's own boundary is the sample with teeth: it is the
        // narrowest width that still draws the badge, so a reporter that took even a
        // single point of the row's width would drop it and be caught here. The round
        // widths cannot catch that on their own — the row draws the same thing for tens
        // of points either side of each of them.
        let boundary = widestWidthWithoutTheBadge()
        let widths: [CGFloat] =
            [Self.roomyWidth, 900, 600, 400, 200, Self.crampedWidth, boundary + 1]
        for width in widths {
            XCTAssertEqual(
                layout(width: width).badge, layout(width: width, observed: false).badge,
                accuracy: 0.5, "observing the row changed its layout at \(width) pt")
        }
    }

    // MARK: - Helpers

    /// A row over a linked workspace that records a base branch (so the Merge chip
    /// shows) and carries two named commands (so the Run Script chip shows) — the same
    /// fixture `WorkspaceToolbarActionsTests` measures the ladder with.
    private func makeModelAndWorkspace() -> (AppModel, Workspace) {
        let workspace = Workspace(
            name: "feature", worktreePath: "/wt", branch: Self.branch,
            portBase: 40000, layout: .leaf(Surface.terminal(cwd: "/wt")),
            kind: .linked, baseBranch: "main")
        let space = Space(
            name: "casper", folderPath: "/repo", isGitRepo: true, workspaces: [workspace])
        let model = makeModel(spaces: [space], selecting: workspace.id)
        model.namedCommandsCache[workspace.id] = [
            RepoNamedCommand(name: "build", command: "make build"),
            RepoNamedCommand(name: "test", command: "make test"),
        ]
        return (model, workspace)
    }

    /// The production row at `width`, reporting its rungs to `report`.
    private func row(
        width: CGFloat, diff: (insertions: Int, deletions: Int)? = (12, 3),
        report: ((TitleBarRung) -> Void)?
    ) -> some View {
        let (model, workspace) = makeModelAndWorkspace()
        return WorkspaceTitleBarRow(
            model: model, workspace: workspace, diff: diff, width: width)
            .reportingRung(report)
    }

    /// Hosts the row at `width` and reports every rung it named plus the width the badge
    /// slot took (0 when the rung dropped the badge).
    private func layout(
        width: CGFloat, observed: Bool = true
    ) -> (rungs: [TitleBarRung], badge: CGFloat) {
        let (model, workspace) = makeModelAndWorkspace()
        var rungs: [TitleBarRung] = []
        var badge: CGFloat = -1
        let row = WorkspaceTitleBarRow(
            model: model, workspace: workspace, diff: (12, 3), width: width,
            onBadgeWidth: { badge = $0 })
            .reportingRung(observed ? { rungs.append($0) } : nil)
        let host = NSHostingView(rootView: row)
        host.frame = NSRect(x: 0, y: 0, width: width, height: TitleCapsuleMetrics.height)
        host.layoutSubtreeIfNeeded()
        return (rungs, badge)
    }

    /// The widest width at which the row drops the diff badge, to the point.
    ///
    /// Searched for rather than written down, since which width that is depends on
    /// hosted geometry and so differs between this machine and the CI runner. Bisected
    /// because the badge is monotone in width — that is what
    /// `WorkspaceToolbarActionsTests.testDegradationIsMonotoneAcrossTheWholeRange` pins
    /// — so the boundary costs ten hosted layouts rather than a sweep.
    ///
    /// Measured on the UNOBSERVED row, which is what makes the boundary usable as a
    /// probe: it is then the row's own, and a reporter that moved it by even a point
    /// shows up as a badge drawn on one side of the comparison and not the other.
    private func widestWidthWithoutTheBadge() -> CGFloat {
        // Both ends of the range, before the search that assumes them. A bisection over
        // a predicate that never flips returns an endpoint whatever the row does, so a
        // badge that stopped rendering everywhere would hand both callers the cramped
        // width and they would measure the wrong row without failing.
        XCTAssertGreaterThan(
            layout(width: Self.sweepWidth, observed: false).badge, 0.5,
            "no badge at \(Self.sweepWidth) pt, so there is no boundary below it")
        XCTAssertLessThan(
            layout(width: Self.crampedWidth, observed: false).badge, 0.5,
            "a badge at \(Self.crampedWidth) pt, so there is no boundary above it")

        var withBadge = Self.sweepWidth
        var without = Self.crampedWidth
        while withBadge - without > 1 {
            let middle = ((withBadge + without) / 2).rounded()
            if layout(width: middle, observed: false).badge > 0.5 {
                withBadge = middle
            } else {
                without = middle
            }
        }
        return without
    }
}
