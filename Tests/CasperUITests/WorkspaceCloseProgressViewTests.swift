import SwiftUI
import XCTest
@testable import CasperUI

/// Rendering smoke tests for the close/delete progress sheet.
///
/// The view has no logic to unit-test — it is a pure function of its `progress`
/// value — so what is worth locking in is that it actually *builds and lays out*:
/// a body that fails to compose, or one whose fixed width stops containing the
/// arbitrary-length branch names the step labels interpolate, would collapse or
/// stretch here rather than only in the running app.
@MainActor
final class WorkspaceCloseProgressViewTests: XCTestCase {
    /// A branch name far longer than the sheet is wide, of the kind the step
    /// labels interpolate verbatim.
    private static let longBranchName = String(repeating: "very-long-feature-branch-name-", count: 12)

    func testLaysOutAtDeclaredWidthWithNonZeroHeight() {
        let size = layoutSize(for: makeProgress(label: "Merging \u{201c}feature\u{201d} into \u{201c}main\u{201d}\u{2026}"))

        XCTAssertEqual(size.width, WorkspaceCloseProgressView.width, accuracy: 0.5)
        XCTAssertGreaterThan(size.height, 0)
    }

    /// The sheet must absorb an arbitrarily long branch name by wrapping and
    /// truncating the step label, not by widening — and `lineLimit(2,
    /// reservesSpace: true)` must cap the extra height at the single line the
    /// short-label case does not use.
    func testLongBranchNameNeitherWidensNorGrowsTheSheet() {
        let shortSize = layoutSize(for: makeProgress(label: "Merging \u{201c}x\u{201d} into \u{201c}main\u{201d}\u{2026}"))
        let longLabel = "Merging \u{201c}\(Self.longBranchName)\u{201d} into \u{201c}main\u{201d}\u{2026}"
        let longSize = layoutSize(for: makeProgress(label: longLabel))

        XCTAssertEqual(longSize.width, WorkspaceCloseProgressView.width, accuracy: 0.5)
        // Both labels reserve two lines, so in practice the long one adds no height
        // at all. The one-line slack keeps the assertion aimed at the real failure —
        // an unbounded label pushing the sheet open — rather than at font metrics.
        XCTAssertLessThanOrEqual(longSize.height, shortSize.height + Self.singleLineAllowance)
    }

    /// The countdown step renders through a `TimelineView`, a different branch of
    /// `stepLabel` than the plain-label steps, so it needs its own smoke test.
    ///
    /// Note the reach: because the label reserves two lines either way, this pins
    /// down that the timeline branch composes and the sheet still lays out — not
    /// that the countdown text itself is non-empty, which the fixed geometry hides.
    func testCountdownStepLaysOut() {
        let progress = makeProgress(
            label: "Running teardown hook\u{2026}",
            deadline: Date().addingTimeInterval(30))

        let size = layoutSize(for: progress)

        XCTAssertEqual(size.width, WorkspaceCloseProgressView.width, accuracy: 0.5)
        XCTAssertGreaterThan(size.height, 0)
    }

    // MARK: - Helpers

    /// One line of `.callout` text, which measures 15pt here, plus a little slack.
    private static let singleLineAllowance: CGFloat = 16

    private func makeProgress(label: String, deadline: Date? = nil) -> WorkspaceCloseProgress {
        WorkspaceCloseProgress(
            id: UUID(),
            title: "Closing \u{201c}feature\u{201d}",
            stepIndex: 2,
            stepCount: 4,
            label: label,
            deadline: deadline)
    }

    /// Host the real view in AppKit and return the size it lays out to.
    private func layoutSize(for progress: WorkspaceCloseProgress) -> NSSize {
        let host = NSHostingView(rootView: WorkspaceCloseProgressView(progress: progress))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }
}
