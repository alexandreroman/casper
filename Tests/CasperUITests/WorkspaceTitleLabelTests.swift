import SwiftUI
import XCTest
@testable import CasperUI

/// Layout regression tests for the title-bar workspace label.
///
/// The label has no logic to unit-test — it is a pure function of its three
/// inputs — but it does have one hard geometric contract: it lives in the
/// leading toolbar group, which the toolbar proposes an arbitrarily small width
/// once the trailing chips have taken their share of a narrow window, and it
/// must answer that by truncating rather than wrapping. Left unbounded it wraps
/// mid-word instead, stacking "casper / docs" onto two or three lines and
/// pushing the whole title bar open. Every test below therefore measures the
/// hosted label's *height* across a sweep of hostile widths and pins it to the
/// height it takes when it has all the room it wants.
@MainActor
final class WorkspaceTitleLabelTests: XCTestCase {
    /// Enough room for any of the labels below to lay out in full — the
    /// one-line baseline every narrow measurement is compared against.
    private static let generousWidth: CGFloat = 600

    /// Widths from "the real ~900pt-window case" down to absurd. The label must
    /// hold at one line throughout, in both of the forms the row asks it for.
    private static let narrowWidths: [CGFloat] = [220, 140, 100, 70, 40]

    /// The reported case: a short Space name and a short branch still wrapped,
    /// measuring 16pt tall at 140pt but 32pt at 90pt and 96pt at 60pt.
    func testGitBackedTitleNeverWraps() {
        assertStaysOnOneLine(isGitRepo: true, spaceName: "casper", branchLabel: "docs")
    }

    /// A branch name several times wider than the group will ever be, so the
    /// branch middle-truncates in either form — which is not allowed to cost a
    /// second line.
    func testLongBranchNameNeverWraps() {
        assertStaysOnOneLine(
            isGitRepo: true,
            spaceName: "my-monorepo",
            branchLabel: "feature/fix-workspace-title-wrapping")
    }

    /// A non-Git Space takes the other branch of the body — one glyph and the
    /// folder name, identical in both forms because there is no Space/branch split
    /// to collapse — so it needs its own coverage of the same contract.
    func testNonGitSpaceNameNeverWraps() {
        assertStaysOnOneLine(
            isGitRepo: false,
            spaceName: "a-rather-long-plain-folder-name-without-a-repository",
            branchLabel: "unused")
    }

    // MARK: - Helpers

    /// Measure the label at every hostile width and assert its height matches
    /// the unconstrained, definitively-one-line baseline.
    private func assertStaysOnOneLine(
        isGitRepo: Bool,
        spaceName: String,
        branchLabel: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for form in [WorkspaceTitleLabel.Form.spaceAndBranch, .branchOnly] {
            let label = WorkspaceTitleLabel(
                isGitRepo: isGitRepo, spaceName: spaceName, branchLabel: branchLabel, form: form)
            let baseline = height(of: label, width: Self.generousWidth)
            XCTAssertGreaterThan(
                baseline, 0, "the label must actually lay out", file: file, line: line)

            for width in Self.narrowWidths {
                XCTAssertEqual(
                    height(of: label, width: width), baseline, accuracy: 0.5,
                    "\(form) wrapped instead of truncating at \(width)pt", file: file, line: line)
            }
        }
    }

    /// Host the real view in AppKit at the given proposed width and return the
    /// height it lays out to.
    private func height(of label: WorkspaceTitleLabel, width: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: label.frame(width: width))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }
}
