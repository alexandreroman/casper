import CasperGit
import SwiftUI
import XCTest
@testable import CasperUI

final class DiffLineStyleTests: XCTestCase {
    /// `nil` for a context line, not a space: the cue is drawn in the gutter, and
    /// a space would be a glyph painted for a row that has nothing to announce.
    func testCue() {
        XCTAssertEqual(DiffLineStyle.cue(for: .addition), "+")
        XCTAssertEqual(DiffLineStyle.cue(for: .deletion), "-")
        XCTAssertNil(DiffLineStyle.cue(for: .context))
    }

    func testTintsMatchClaudeCodeReference() {
        XCTAssertEqual(DiffLineStyle.insertionTint, Color(red: 0.529, green: 0.757, blue: 0.388))
        XCTAssertEqual(DiffLineStyle.deletionTint, Color(red: 0.725, green: 0.416, blue: 0.369))
    }

    func testBackgroundIsASolidSaturatedColor() {
        XCTAssertEqual(DiffLineStyle.background(for: .addition), Color(red: 0.082, green: 0.149, blue: 0.024))
        XCTAssertEqual(DiffLineStyle.background(for: .deletion), Color(red: 0.188, green: 0.043, blue: 0.012))
        XCTAssertEqual(DiffLineStyle.background(for: .context), Color.clear)
    }

    /// A conflicted file is the one status the header has to make impossible to
    /// read past, and an unreadable one the one it has to make impossible to mistake
    /// for a real change. Everything else is chrome, including `unmodified` — which
    /// is what a conflict used to be labelled before `GitDiffFile.Status` could say
    /// otherwise.
    func testConflictedAndUnreadableStandApartFromOrdinaryStatuses() {
        XCTAssertEqual(DiffLineStyle.statusEmphasis(for: .conflicted), .warning(DiffLineStyle.deletionTint))
        XCTAssertEqual(DiffLineStyle.statusEmphasis(for: .unreadable),
                       .muted(Color(nsColor: .tertiaryLabelColor)))
        for status: GitDiffFile.Status in [.added, .deleted, .modified, .renamed, .copied,
                                           .typechange, .unmodified] {
            XCTAssertEqual(DiffLineStyle.statusEmphasis(for: status), .chrome, "\(status)")
        }
    }

    func testLineNumberPicksOldForDeletionAndNewForAdditionOrContext() {
        let deletion = GitDiffLine(kind: .deletion, content: "x", oldLineNumber: 30, newLineNumber: nil)
        let addition = GitDiffLine(kind: .addition, content: "x", oldLineNumber: nil, newLineNumber: 31)
        let context = GitDiffLine(kind: .context, content: "x", oldLineNumber: 5, newLineNumber: 5)

        XCTAssertEqual(DiffLineStyle.lineNumber(for: deletion), 30)
        XCTAssertEqual(DiffLineStyle.lineNumber(for: addition), 31)
        XCTAssertEqual(DiffLineStyle.lineNumber(for: context), 5)
    }

    func testTruncatedForDisplayLeavesShortStringUnchanged() {
        let short = String(repeating: "a", count: 42)
        let result = DiffLineStyle.truncatedForDisplay(short)
        XCTAssertEqual(result.text, short)
        XCTAssertFalse(result.truncated)
    }

    func testTruncatedForDisplayLeavesExactlyCapLengthUnchanged() {
        let exact = String(repeating: "a", count: DiffLineStyle.maxDisplayLineLength)
        let result = DiffLineStyle.truncatedForDisplay(exact)
        XCTAssertEqual(result.text, exact)
        XCTAssertFalse(result.truncated)
    }

    func testTruncatedForDisplayTruncatesOnePastCap() {
        let overCap = String(repeating: "a", count: DiffLineStyle.maxDisplayLineLength + 1)
        let result = DiffLineStyle.truncatedForDisplay(overCap)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.text.count, DiffLineStyle.maxDisplayLineLength)
    }

    func testTruncatedForDisplayTruncatesMultiMegabyteLine() {
        let huge = String(repeating: "a", count: 5_000_000)
        let result = DiffLineStyle.truncatedForDisplay(huge)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.text.count, DiffLineStyle.maxDisplayLineLength)
    }
}
