import AppKit
import CasperGit
import SwiftUI
import XCTest
@testable import CasperUI

/// The assembly step owns every attribute the renderer draws with, and it is the
/// gate that keeps a syntax highlight from reflowing the document.
@MainActor
final class DiffTextAssemblyTests: XCTestCase {
    private func document(_ lines: [GitDiffLine], path: String = "a.swift") -> DiffDocument {
        let hunk = GitDiffHunk(header: "@@ -1,1 +1,1 @@", oldStart: 1, oldLines: lines.count,
                               newStart: 1, newLines: lines.count, lines: lines)
        return DiffDocument(diff: GitDiff(files: [
            GitDiffFile(oldPath: path, newPath: path, status: .modified,
                        isBinary: false, hunks: [hunk]),
        ]))
    }

    private func attribute(
        _ key: NSAttributedString.Key, at offset: Int, in storage: NSTextStorage
    ) -> Any? {
        storage.attribute(key, at: offset, effectiveRange: nil)
    }

    /// Builds a highlight the way the real producer does. HighlightSwift ends its
    /// conversion with `AttributedString(_:including: \.appKit)`, so the colors a
    /// run carries live in the **AppKit** scope; an `AttributedString` given a
    /// SwiftUI `Color` instead would assert against a scope production never sees.
    ///
    /// The input does not come from `DiffHighlighter.highlightedLines` itself
    /// because that returns `nil` under XCTest: it needs HighlightSwift's resource
    /// bundle next to `Bundle.main`, which is the toolchain's `usr/bin` here.
    private func highlight(_ segments: [(String, NSColor)]) throws -> AttributedString {
        let source = NSMutableAttributedString()
        for (text, color) in segments {
            source.append(NSAttributedString(string: text, attributes: [.foregroundColor: color]))
        }
        let highlighted = try AttributedString(source, including: \.appKit)
        XCTAssertNil(highlighted.runs.first?.attributes.swiftUI.foregroundColor,
                     "the input must carry no SwiftUI-scope color, or it would not pin the scope")
        return highlighted
    }

    func testStorageTextMatchesTheDocument() {
        let doc = document([GitDiffLine(kind: .addition, content: "let x = 1",
                                        oldLineNumber: nil, newLineNumber: 1)])
        let storage = DiffTextAssembly.makeTextStorage(for: doc)

        XCTAssertEqual(storage.string, doc.text)
    }

    func testPrefixCarriesTheAccentAndContentTheNeutralColor() {
        let doc = document([GitDiffLine(kind: .addition, content: "let x = 1",
                                        oldLineNumber: nil, newLineNumber: 1)])
        let storage = DiffTextAssembly.makeTextStorage(for: doc)
        let span = doc.lines[1]

        XCTAssertEqual(attribute(.foregroundColor, at: span.range.location, in: storage) as? NSColor,
                       NSColor(DiffLineStyle.accent(for: .addition)))
        XCTAssertEqual(attribute(.foregroundColor, at: span.contentRange.location, in: storage) as? NSColor,
                       NSColor.labelColor)
    }

    func testCodeLinesCarryTheCodeFont() {
        let doc = document([GitDiffLine(kind: .addition, content: "let x = 1",
                                        oldLineNumber: nil, newLineNumber: 1)])
        let storage = DiffTextAssembly.makeTextStorage(for: doc)
        let span = doc.lines[1]

        XCTAssertEqual(attribute(.font, at: span.contentRange.location, in: storage) as? NSFont,
                       DiffTextAssembly.codeFont)
        XCTAssertEqual(attribute(.font, at: span.range.location, in: storage) as? NSFont,
                       DiffTextAssembly.codeFont)
        XCTAssertEqual(DiffTextAssembly.codeFont.pointSize, 14)
    }

    /// Chrome mirrors the row-based renderer exactly: `.caption` for both, but
    /// monospaced for the positional hunk header and proportional for the notes.
    func testChromeLinesCarryTheCaptionSizedFontsAndTheDimColor() {
        let hunk = GitDiffHunk(header: "@@ -1,1 +1,1 @@", oldStart: 1, oldLines: 1,
                               newStart: 1, newLines: 1,
                               lines: [GitDiffLine(kind: .context, content: "x",
                                                   oldLineNumber: 1, newLineNumber: 1)])
        let doc = DiffDocument(diff: GitDiff(files: [
            GitDiffFile(oldPath: "a.swift", newPath: "a.swift", status: .modified,
                        isBinary: false, hunks: [hunk]),
            GitDiffFile(oldPath: "logo.png", newPath: "logo.png", status: .modified,
                        isBinary: true, hunks: []),
        ]))
        let storage = DiffTextAssembly.makeTextStorage(for: doc)

        let header = doc.lines[0]
        XCTAssertEqual(header.kind, .hunkHeader)
        XCTAssertEqual(attribute(.font, at: header.range.location, in: storage) as? NSFont,
                       DiffTextAssembly.hunkHeaderFont)
        XCTAssertEqual(attribute(.foregroundColor, at: header.range.location, in: storage) as? NSColor,
                       NSColor.secondaryLabelColor)

        let note = doc.lines[doc.files[1].firstLineIndex]
        XCTAssertEqual(note.kind, .note)
        XCTAssertEqual(attribute(.font, at: note.range.location, in: storage) as? NSFont,
                       DiffTextAssembly.noteFont)
        XCTAssertEqual(attribute(.foregroundColor, at: note.range.location, in: storage) as? NSColor,
                       NSColor.secondaryLabelColor)

        // Visual parity with the renderer this replaces: both were `.caption`,
        // and the note was the proportional face while the header was monospaced.
        XCTAssertEqual(NSFont.preferredFont(forTextStyle: .caption1).pointSize,
                       DiffTextAssembly.chromeFontSize,
                       "the chrome size mirrors `.caption`; if the platform moved, so must the constant")
        XCTAssertEqual(DiffTextAssembly.hunkHeaderFont.pointSize, DiffTextAssembly.chromeFontSize)
        XCTAssertEqual(DiffTextAssembly.noteFont.pointSize, DiffTextAssembly.chromeFontSize)
        XCTAssertNotEqual(DiffTextAssembly.noteFont.fontName, DiffTextAssembly.hunkHeaderFont.fontName)
    }

    func testEveryLineIsWordWrappingSoNothingScrollsHorizontally() {
        let doc = document([GitDiffLine(kind: .context, content: "x",
                                        oldLineNumber: 1, newLineNumber: 1)])
        let storage = DiffTextAssembly.makeTextStorage(for: doc)

        for span in doc.lines {
            let style = attribute(.paragraphStyle, at: span.range.location, in: storage)
            XCTAssertEqual((style as? NSParagraphStyle)?.lineBreakMode, .byWordWrapping)
        }
    }

    /// `NSAttributedString` stores a paragraph style by reference, so a mutable
    /// instance in the storage would let one downcast reflow every paragraph of
    /// every document at once.
    func testParagraphStylesAreImmutableInstances() {
        let hunk = GitDiffHunk(header: "@@ -1,1 +1,1 @@", oldStart: 1, oldLines: 1,
                               newStart: 1, newLines: 1,
                               lines: [GitDiffLine(kind: .context, content: "x",
                                                   oldLineNumber: 1, newLineNumber: 1)])
        let doc = DiffDocument(diff: GitDiff(files: [
            GitDiffFile(oldPath: "a.swift", newPath: "a.swift", status: .modified,
                        isBinary: false, hunks: [hunk]),
            GitDiffFile(oldPath: "b.swift", newPath: "b.swift", status: .modified,
                        isBinary: false, hunks: [hunk]),
        ]))
        let storage = DiffTextAssembly.makeTextStorage(for: doc)

        for span in doc.lines {
            let style = attribute(.paragraphStyle, at: span.range.location, in: storage)
            XCTAssertFalse(style is NSMutableParagraphStyle, "paragraph style must be an immutable copy")
        }
    }

    /// The blank band the sticky header draws into is reserved by paragraph
    /// spacing rather than by characters, so selection and copy stay clean.
    func testFilesAfterTheFirstReserveTheStickyHeaderBand() {
        let hunk = GitDiffHunk(header: "@@ -1,1 +1,1 @@", oldStart: 1, oldLines: 1,
                               newStart: 1, newLines: 1,
                               lines: [GitDiffLine(kind: .context, content: "x",
                                                   oldLineNumber: 1, newLineNumber: 1)])
        let doc = DiffDocument(diff: GitDiff(files: [
            GitDiffFile(oldPath: "a.swift", newPath: "a.swift", status: .modified,
                        isBinary: false, hunks: [hunk]),
            GitDiffFile(oldPath: "b.swift", newPath: "b.swift", status: .modified,
                        isBinary: false, hunks: [hunk]),
        ]))
        let storage = DiffTextAssembly.makeTextStorage(for: doc)

        let firstStyle = attribute(.paragraphStyle, at: doc.files[0].range.location, in: storage)
        let secondStyle = attribute(.paragraphStyle, at: doc.files[1].range.location, in: storage)
        XCTAssertEqual((firstStyle as? NSParagraphStyle)?.paragraphSpacingBefore, 0)
        XCTAssertEqual((secondStyle as? NSParagraphStyle)?.paragraphSpacingBefore,
                       DiffTextAssembly.headerBandHeight + DiffTextAssembly.interFileGap)
        // The band is reserved on the file's first paragraph only, not the rest.
        XCTAssertEqual((attribute(.paragraphStyle, at: doc.lines[3].range.location, in: storage)
                        as? NSParagraphStyle)?.paragraphSpacingBefore, 0)
    }

    /// The `… (line truncated)` marker is Casper's own commentary, so it reads as
    /// chrome from its first character to its last.
    func testTruncationMarkerIsDimmedOverItsWholeLength() {
        let long = String(repeating: "x", count: DiffLineStyle.maxDisplayLineLength + 10)
        let doc = document([GitDiffLine(kind: .addition, content: long,
                                        oldLineNumber: nil, newLineNumber: 1)])
        let storage = DiffTextAssembly.makeTextStorage(for: doc)
        let span = doc.lines[1]
        XCTAssertTrue(span.truncated)

        for offset in [NSMaxRange(span.contentRange), NSMaxRange(span.range) - 1] {
            XCTAssertEqual(attribute(.foregroundColor, at: offset, in: storage) as? NSColor,
                           NSColor.secondaryLabelColor, "offset \(offset)")
        }
        XCTAssertEqual(attribute(.foregroundColor, at: span.contentRange.location, in: storage) as? NSColor,
                       NSColor.labelColor)
    }

    func testHighlightRecolorsTheContentOnly() throws {
        let doc = document([GitDiffLine(kind: .addition, content: "abc",
                                        oldLineNumber: nil, newLineNumber: 1)])
        let storage = DiffTextAssembly.makeTextStorage(for: doc)
        let highlighted = try highlight([("abc", .systemPink)])

        DiffTextAssembly.applyHighlight(
            DiffFileHighlight(new: [highlighted], old: nil),
            forFileAt: 0, in: storage, document: doc)

        let span = doc.lines[1]
        XCTAssertEqual(attribute(.foregroundColor, at: span.contentRange.location, in: storage) as? NSColor,
                       NSColor.systemPink)
        // The prefix keeps its accent: the diff cue must survive highlighting.
        XCTAssertEqual(attribute(.foregroundColor, at: span.range.location, in: storage) as? NSColor,
                       NSColor(DiffLineStyle.accent(for: .addition)))
    }

    /// A SwiftUI-scope color is not what the highlighter emits, but reading that
    /// scope too costs nothing and keeps the function usable by either producer.
    func testASwiftUIScopeColorIsStillHonoured() {
        let doc = document([GitDiffLine(kind: .addition, content: "abc",
                                        oldLineNumber: nil, newLineNumber: 1)])
        let storage = DiffTextAssembly.makeTextStorage(for: doc)
        var highlighted = AttributedString("abc")
        highlighted.foregroundColor = .purple

        DiffTextAssembly.applyHighlight(
            DiffFileHighlight(new: [highlighted], old: nil),
            forFileAt: 0, in: storage, document: doc)

        XCTAssertEqual(
            attribute(.foregroundColor, at: doc.lines[1].contentRange.location, in: storage) as? NSColor,
            NSColor(Color.purple))
    }

    /// Every run lands on its own characters and only those, so a mis-measured run
    /// length cannot shift the colors that follow it.
    func testEachRunLandsOnItsOwnCharacters() throws {
        let doc = document([GitDiffLine(kind: .addition, content: "let xy = 1",
                                        oldLineNumber: nil, newLineNumber: 1)])
        let storage = DiffTextAssembly.makeTextStorage(for: doc)
        let segments: [(String, NSColor)] = [("let", .systemPink), (" xy", .systemTeal), (" = 1", .systemYellow)]
        let highlighted = try highlight(segments)
        XCTAssertEqual(highlighted.runs.count, segments.count)

        DiffTextAssembly.applyHighlight(
            DiffFileHighlight(new: [highlighted], old: nil),
            forFileAt: 0, in: storage, document: doc)

        var offset = doc.lines[1].contentRange.location
        for (text, color) in segments {
            let length = text.utf16.count
            for probe in [offset, offset + length - 1] {
                XCTAssertEqual(attribute(.foregroundColor, at: probe, in: storage) as? NSColor,
                               color, "offset \(probe) of \"\(text)\"")
            }
            offset += length
        }
    }

    /// Run lengths are counted in UTF-16 units, so a run that ends inside a
    /// surrogate pair or past a multi-byte scalar must still cover exactly its own
    /// code units.
    func testNonASCIIContentIsColoredAtTheRightOffsets() throws {
        let doc = document([GitDiffLine(kind: .addition, content: "let é = 😀",
                                        oldLineNumber: nil, newLineNumber: 1)])
        let storage = DiffTextAssembly.makeTextStorage(for: doc)
        let highlighted = try highlight([("let", .systemPink), (" é = 😀", .systemTeal)])

        DiffTextAssembly.applyHighlight(
            DiffFileHighlight(new: [highlighted], old: nil),
            forFileAt: 0, in: storage, document: doc)

        let content = doc.lines[1].contentRange
        XCTAssertEqual(content.length, "let é = 😀".utf16.count)
        XCTAssertEqual(attribute(.foregroundColor, at: content.location, in: storage) as? NSColor,
                       NSColor.systemPink)
        XCTAssertEqual(attribute(.foregroundColor, at: content.location + 3, in: storage) as? NSColor,
                       NSColor.systemTeal)
        // The last code unit is the emoji's low surrogate: the run must reach it.
        XCTAssertEqual(attribute(.foregroundColor, at: NSMaxRange(content) - 1, in: storage) as? NSColor,
                       NSColor.systemTeal)
    }

    func testHighlightNeverChangesLayoutMetrics() throws {
        let doc = document([GitDiffLine(kind: .addition, content: "abc",
                                        oldLineNumber: nil, newLineNumber: 1)])
        let storage = DiffTextAssembly.makeTextStorage(for: doc)
        let span = doc.lines[1]
        let before = storage.attributes(at: span.contentRange.location, effectiveRange: nil)
        var highlighted = try highlight([("abc", .systemPink)])
        highlighted.font = .system(size: 96)  // a metric-bearing attribute, must be ignored

        DiffTextAssembly.applyHighlight(
            DiffFileHighlight(new: [highlighted], old: nil),
            forFileAt: 0, in: storage, document: doc)

        // Proof the pass actually wrote something for this font-carrying input —
        // without it every assertion below also holds for an inert implementation.
        let after = storage.attributes(at: span.contentRange.location, effectiveRange: nil)
        XCTAssertEqual(after[.foregroundColor] as? NSColor, NSColor.systemPink)

        // `.foregroundColor` is the only key whose value moved, which covers the
        // metric-bearing attributes by name (font, paragraph style) and the ones
        // nobody thinks of (kern, baseline offset, ligature, tracking) alike.
        var beforeRest = before
        var afterRest = after
        beforeRest[.foregroundColor] = nil
        afterRest[.foregroundColor] = nil
        XCTAssertEqual(beforeRest as NSDictionary, afterRest as NSDictionary)
        XCTAssertEqual(storage.string, doc.text)
    }

    /// A highlighted string whose length disagrees with the diff line means the
    /// two sources drifted; neutral text beats misaligned colors.
    func testLengthMismatchLeavesTheLineNeutral() throws {
        let doc = document([GitDiffLine(kind: .addition, content: "abc",
                                        oldLineNumber: nil, newLineNumber: 1)])
        let storage = DiffTextAssembly.makeTextStorage(for: doc)
        let wrongLength = try highlight([("abcdef", .systemPink)])

        DiffTextAssembly.applyHighlight(
            DiffFileHighlight(new: [wrongLength], old: nil),
            forFileAt: 0, in: storage, document: doc)

        let span = doc.lines[1]
        XCTAssertEqual(attribute(.foregroundColor, at: span.contentRange.location, in: storage) as? NSColor,
                       NSColor.labelColor)
    }

    func testTruncatedLineIsNeverHighlighted() throws {
        let long = String(repeating: "x", count: DiffLineStyle.maxDisplayLineLength + 10)
        let doc = document([GitDiffLine(kind: .addition, content: long,
                                        oldLineNumber: nil, newLineNumber: 1)])
        let storage = DiffTextAssembly.makeTextStorage(for: doc)
        // Exactly the displayed content, so the length guard agrees and being
        // truncated is the only reason this line can be skipped.
        let displayed = String(long.prefix(DiffLineStyle.maxDisplayLineLength))
        let highlighted = try highlight([(displayed, .systemPink)])
        let span = doc.lines[1]
        XCTAssertEqual(displayed.utf16.count, span.contentRange.length)

        DiffTextAssembly.applyHighlight(
            DiffFileHighlight(new: [highlighted], old: nil),
            forFileAt: 0, in: storage, document: doc)

        XCTAssertEqual(attribute(.foregroundColor, at: span.contentRange.location, in: storage) as? NSColor,
                       NSColor.labelColor)
    }

    func testDeletionReadsTheHeadSideOfTheHighlight() throws {
        let doc = document([GitDiffLine(kind: .deletion, content: "old",
                                        oldLineNumber: 1, newLineNumber: nil)])
        let storage = DiffTextAssembly.makeTextStorage(for: doc)
        let newSide = try highlight([("old", .systemTeal)])
        let oldSide = try highlight([("old", .systemPink)])

        DiffTextAssembly.applyHighlight(
            DiffFileHighlight(new: [newSide], old: [oldSide]),
            forFileAt: 0, in: storage, document: doc)

        XCTAssertEqual(
            attribute(.foregroundColor, at: doc.lines[1].contentRange.location, in: storage) as? NSColor,
            NSColor.systemPink)
    }

    /// Chrome lines share the file's line range but have no source line, so a
    /// highlight array long enough to reach them must not touch them.
    func testHunkHeaderKeepsItsChromeStylingInAHighlightedFile() throws {
        let doc = document([GitDiffLine(kind: .addition, content: "abc",
                                        oldLineNumber: nil, newLineNumber: 1)])
        let storage = DiffTextAssembly.makeTextStorage(for: doc)
        let highlighted = try highlight([("abc", .systemPink)])

        DiffTextAssembly.applyHighlight(
            DiffFileHighlight(new: [highlighted, highlighted], old: nil),
            forFileAt: 0, in: storage, document: doc)

        let header = doc.lines[0]
        XCTAssertEqual(attribute(.foregroundColor, at: header.range.location, in: storage) as? NSColor,
                       NSColor.secondaryLabelColor)
        XCTAssertEqual(attribute(.font, at: header.range.location, in: storage) as? NSFont,
                       DiffTextAssembly.hunkHeaderFont)
    }

    func testHighlightForAFileIndexOutOfRangeIsIgnored() throws {
        let doc = document([GitDiffLine(kind: .addition, content: "abc",
                                        oldLineNumber: nil, newLineNumber: 1)])
        let storage = DiffTextAssembly.makeTextStorage(for: doc)
        let highlighted = try highlight([("abc", .systemPink)])

        DiffTextAssembly.applyHighlight(
            DiffFileHighlight(new: [highlighted], old: nil),
            forFileAt: 7, in: storage, document: doc)

        XCTAssertEqual(storage.string, doc.text)
        XCTAssertEqual(
            attribute(.foregroundColor, at: doc.lines[1].contentRange.location, in: storage) as? NSColor,
            NSColor.labelColor)
    }

    /// The length-equality guard. A storage assembled from another document has
    /// unrelated offsets, so this document's ranges would recolor arbitrary text —
    /// or index past the end.
    func testAStorageFromAnotherDocumentIsRefused() throws {
        let doc = document([GitDiffLine(kind: .addition, content: "abc",
                                        oldLineNumber: nil, newLineNumber: 1)])
        let other = document([GitDiffLine(kind: .addition, content: "a considerably longer line",
                                          oldLineNumber: nil, newLineNumber: 1)], path: "b.swift")
        let storage = DiffTextAssembly.makeTextStorage(for: other)
        let highlighted = try highlight([("abc", .systemPink)])

        DiffTextAssembly.applyHighlight(
            DiffFileHighlight(new: [highlighted], old: nil),
            forFileAt: 0, in: storage, document: doc)

        XCTAssertEqual(storage.string, other.text)
        XCTAssertEqual(
            attribute(.foregroundColor, at: other.lines[1].contentRange.location, in: storage) as? NSColor,
            NSColor.labelColor)
    }

    /// Highlighting is applied per file as the highlighter finishes it, and a
    /// refresh may run over the same file again, so a second pass must not leave
    /// the first one's colors on a line it now skips.
    func testReapplyingADriftedHighlightRestoresTheNeutralColor() throws {
        let doc = document([GitDiffLine(kind: .addition, content: "abc",
                                        oldLineNumber: nil, newLineNumber: 1)])
        let storage = DiffTextAssembly.makeTextStorage(for: doc)
        DiffTextAssembly.applyHighlight(
            DiffFileHighlight(new: [try highlight([("abc", .systemPink)])], old: nil),
            forFileAt: 0, in: storage, document: doc)

        DiffTextAssembly.applyHighlight(
            DiffFileHighlight(new: [try highlight([("abcdef", .systemTeal)])], old: nil),
            forFileAt: 0, in: storage, document: doc)

        XCTAssertEqual(
            attribute(.foregroundColor, at: doc.lines[1].contentRange.location, in: storage) as? NSColor,
            NSColor.labelColor)
    }

    func testAnUncoloredRunResetsAPreviouslyColoredLine() throws {
        let doc = document([GitDiffLine(kind: .addition, content: "abc",
                                        oldLineNumber: nil, newLineNumber: 1)])
        let storage = DiffTextAssembly.makeTextStorage(for: doc)
        DiffTextAssembly.applyHighlight(
            DiffFileHighlight(new: [try highlight([("abc", .systemPink)])], old: nil),
            forFileAt: 0, in: storage, document: doc)

        DiffTextAssembly.applyHighlight(
            DiffFileHighlight(new: [AttributedString("abc")], old: nil),
            forFileAt: 0, in: storage, document: doc)

        XCTAssertEqual(
            attribute(.foregroundColor, at: doc.lines[1].contentRange.location, in: storage) as? NSColor,
            NSColor.labelColor)
    }
}
