import AppKit
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

    /// Resolves `color` under `appearance` to sRGB components, the way AppKit does
    /// at draw time for a dynamic colour.
    private func components(_ color: Color, in name: NSAppearance.Name) -> [CGFloat] {
        var result: [CGFloat] = []
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            let resolved = NSColor(color).usingColorSpace(.sRGB)!
            result = [resolved.redComponent, resolved.greenComponent, resolved.blueComponent]
        }
        return result
    }

    private func assertColor(
        _ color: Color, dark: [CGFloat], light: [CGFloat], file: StaticString = #filePath, line: UInt = #line
    ) {
        for (expected, name) in [(dark, NSAppearance.Name.darkAqua), (light, .aqua)] {
            let actual = components(color, in: name)
            for (a, e) in zip(actual, expected) {
                XCTAssertEqual(a, e, accuracy: 0.002, "\(name.rawValue)", file: file, line: line)
            }
        }
    }

    /// Dark keeps the values sampled from Claude Code's diff; light uses GitHub's.
    func testTintsFollowTheAppearance() {
        let lightInsertion: [CGFloat] = [0x1A, 0x7F, 0x37].map { $0 / 255 }
        let lightDeletion: [CGFloat] = [0xCF, 0x22, 0x2E].map { $0 / 255 }
        assertColor(DiffLineStyle.insertionTint, dark: [0.529, 0.757, 0.388], light: lightInsertion)
        assertColor(DiffLineStyle.deletionTint, dark: [0.725, 0.416, 0.369], light: lightDeletion)
    }

    func testBackgroundsFollowTheAppearance() {
        let lightAddition: [CGFloat] = [0xDA, 0xFB, 0xE1].map { $0 / 255 }
        let lightDeletion: [CGFloat] = [0xFF, 0xEB, 0xE9].map { $0 / 255 }
        assertColor(DiffLineStyle.background(for: .addition), dark: [0.082, 0.149, 0.024], light: lightAddition)
        assertColor(DiffLineStyle.background(for: .deletion), dark: [0.188, 0.043, 0.012], light: lightDeletion)
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
