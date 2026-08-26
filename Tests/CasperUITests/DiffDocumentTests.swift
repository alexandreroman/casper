import CasperGit
import XCTest
@testable import CasperUI

/// `DiffDocument` is the diff view's whole rendering model: everything the
/// TextKit renderer draws is a span it produced. It is pure, so it is the one
/// place the diff view's semantics can be pinned down without a screen.
final class DiffDocumentTests: XCTestCase {
    // MARK: - Builders

    private func line(
        _ kind: GitDiffLine.Kind, _ content: String, old: Int? = nil, new: Int? = nil
    ) -> GitDiffLine {
        GitDiffLine(kind: kind, content: content, oldLineNumber: old, newLineNumber: new)
    }

    private func hunk(header: String = "@@ -1,2 +1,2 @@", _ lines: [GitDiffLine]) -> GitDiffHunk {
        GitDiffHunk(header: header, oldStart: 1, oldLines: lines.count, newStart: 1,
                    newLines: lines.count, lines: lines)
    }

    private func file(
        old: String = "a.swift", new: String = "a.swift",
        status: GitDiffFile.Status = .modified, isBinary: Bool = false,
        _ hunks: [GitDiffHunk]
    ) -> GitDiffFile {
        GitDiffFile(oldPath: old, newPath: new, status: status, isBinary: isBinary, hunks: hunks)
    }

    /// The document substring a span points at, so assertions read as text
    /// rather than as arithmetic on offsets.
    private func text(_ document: DiffDocument, _ range: NSRange) -> String {
        (document.text as NSString).substring(with: range)
    }

    /// What each `"Diff too large — N more lines hidden"` note reports, in
    /// document order.
    ///
    /// The notes are the document's whole account of what the budgets dropped —
    /// nothing exposes a total — so a truncation assertion is an assertion about
    /// them. A note of another kind ("Binary file", "No content changes") parses
    /// to no number and drops out.
    private func hiddenCounts(in document: DiffDocument) -> [Int] {
        document.lines
            .filter { $0.kind == .note }
            .compactMap { Int(text(document, $0.range).split(separator: " ").dropFirst(4).first ?? "") }
    }

    // MARK: - Shape

    func testEmptyDiffProducesEmptyDocument() {
        let document = DiffDocument(diff: GitDiff(files: []))

        XCTAssertTrue(document.text.isEmpty)
        XCTAssertTrue(document.files.isEmpty)
        XCTAssertTrue(document.lines.isEmpty)
    }

    func testHunkHeaderPrecedesItsLines() {
        let document = DiffDocument(diff: GitDiff(files: [
            file([hunk(header: "@@ -1,1 +1,2 @@", [
                line(.context, "keep", old: 1, new: 1),
                line(.addition, "added", new: 2),
            ])]),
        ]))

        XCTAssertEqual(document.lines.map(\.kind), [.hunkHeader, .context, .addition])
        XCTAssertEqual(text(document, document.lines[0].range), "@@ -1,1 +1,2 @@")
        XCTAssertNil(document.lines[0].number)
    }

    /// A diff line is its source text and nothing else: the `+`/`-` cue is drawn
    /// in the gutter, so it neither prefixes the text nor shifts `contentRange`.
    func testDiffLineIsItsSourceTextWithNoCue() {
        let document = DiffDocument(diff: GitDiff(files: [
            file([hunk([line(.addition, "let x = 1", new: 7)])]),
        ]))

        let added = document.lines[1]
        XCTAssertEqual(text(document, added.range), "let x = 1")
        XCTAssertEqual(text(document, added.contentRange), "let x = 1")
        XCTAssertEqual(added.number, 7)
        XCTAssertFalse(added.truncated)
    }

    /// The gutter shows one number per line: the old number for a deletion, the
    /// new number otherwise. That single number is also the index a syntax
    /// highlight is looked up by, so getting the side wrong miscolors the file.
    func testGutterNumberFollowsTheLinesSide() {
        let document = DiffDocument(diff: GitDiff(files: [
            file([hunk([
                line(.deletion, "gone", old: 41),
                line(.addition, "new", new: 42),
                line(.context, "same", old: 43, new: 44),
            ])]),
        ]))

        XCTAssertEqual(document.lines.dropFirst().map(\.number), [41, 42, 44])
    }

    // MARK: - Titles, status, stats

    func testRenameTitleJoinsBothPaths() {
        let document = DiffDocument(diff: GitDiff(files: [
            file(old: "old/a.swift", new: "new/b.swift", status: .renamed,
                 [hunk([line(.context, "x", old: 1, new: 1)])]),
        ]))

        XCTAssertEqual(document.files[0].title, "old/a.swift \u{2192} new/b.swift")
        XCTAssertEqual(document.files[0].status, .renamed)
        XCTAssertEqual(document.files[0].id, "new/b.swift")
    }

    func testDeletionTitleFallsBackToTheOldPath() {
        let document = DiffDocument(diff: GitDiff(files: [
            file(old: "gone.swift", new: "", status: .deleted,
                 [hunk([line(.deletion, "x", old: 1)])]),
        ]))

        XCTAssertEqual(document.files[0].title, "gone.swift")
        XCTAssertEqual(document.files[0].id, "gone.swift")
    }

    func testFileCarriesItsInsertionAndDeletionCounts() {
        let document = DiffDocument(diff: GitDiff(files: [
            file([hunk([
                line(.addition, "a", new: 1),
                line(.addition, "b", new: 2),
                line(.deletion, "c", old: 1),
                line(.context, "d", old: 2, new: 3),
            ])]),
        ]))

        XCTAssertEqual(document.files[0].insertions, 2)
        XCTAssertEqual(document.files[0].deletions, 1)
    }

    /// The gutter must be wide enough for the file's widest line number, with a
    /// floor so short files don't get a cramped column.
    func testGutterWidthGrowsWithTheWidestLineNumber() {
        let narrow = DiffDocument(diff: GitDiff(files: [
            file([hunk([line(.context, "x", old: 1, new: 1)])]),
        ]))
        let wide = DiffDocument(diff: GitDiff(files: [
            file([hunk([line(.context, "x", old: 12345, new: 12345)])]),
        ]))

        XCTAssertEqual(narrow.files[0].gutterWidth, 36)
        XCTAssertEqual(wide.files[0].gutterWidth, CGFloat(5 * 9 + 12))
    }

    // MARK: - Binary files

    func testBinaryFileRendersASingleNote() {
        let document = DiffDocument(diff: GitDiff(files: [
            file(isBinary: true, []),
        ]))

        XCTAssertEqual(document.lines.map(\.kind), [.note])
        XCTAssertEqual(text(document, document.lines[0].range), "Binary file")
        XCTAssertEqual(document.files[0].lineCount, 1)
    }

    /// A non-binary file with no hunks — a mode-only change (`chmod +x`), or the
    /// conflicted entry libgit2 reports for a file whose merge is unresolved. It
    /// still gets a paragraph of its own: a zero-length `FileSpan` would start where
    /// the next file starts, and the geometry could not tell the two apart, so the
    /// file would silently disappear from the view. Its status has to survive the
    /// crossing too — the header is where a conflict is announced, and a file with
    /// nothing to show is exactly where the word is all the reader gets.
    func testFileWithNoHunksRendersASingleNote() throws {
        let document = DiffDocument(diff: GitDiff(files: [
            file(status: .conflicted, []),
        ]))

        XCTAssertEqual(document.lines.map(\.kind), [.note])
        let note = try XCTUnwrap(document.lines.first)
        XCTAssertEqual(text(document, note.range), "No content changes")
        let span = try XCTUnwrap(document.files.first)
        XCTAssertEqual(span.lineCount, 1)
        XCTAssertGreaterThan(span.range.length, 0)
        XCTAssertEqual(span.status, .conflicted)
    }

    // MARK: - Truncation

    func testLongLineIsTruncatedAndMarkedUnhighlightable() {
        let long = String(repeating: "x", count: DiffLineStyle.maxDisplayLineLength + 50)
        let document = DiffDocument(diff: GitDiff(files: [
            file([hunk([line(.addition, long, new: 1)])]),
        ]))

        let added = document.lines[1]
        XCTAssertTrue(added.truncated)
        XCTAssertTrue(text(document, added.range).hasSuffix("(line truncated)"))
        // The content range stops before the marker, so a highlight can never
        // land on text the source line does not have.
        XCTAssertEqual(added.contentRange.length, DiffLineStyle.maxDisplayLineLength)
    }

    func testLineExactlyAtTheCapIsNotTruncated() {
        let exact = String(repeating: "x", count: DiffLineStyle.maxDisplayLineLength)
        let document = DiffDocument(diff: GitDiff(files: [
            file([hunk([line(.addition, exact, new: 1)])]),
        ]))

        XCTAssertFalse(document.lines[1].truncated)
        XCTAssertEqual(text(document, document.lines[1].contentRange), exact)
    }

    // MARK: - Line content

    /// `Repository.mapLine` strips only a trailing LF or CRLF, so a bare `\r`, a
    /// lone trailing `\r` and U+2028 all reach the document as content. TextKit
    /// treats each of them as a paragraph break, which would split one diff line
    /// across several layout fragments — a doubled gutter number and a tinted row
    /// whose gutter number is printed once per fragment instead of once per line.
    func testSeparatorsInsideContentBecomeSpaces() {
        let content = "first\rsecond\u{2028}third\r"
        let document = DiffDocument(diff: GitDiff(files: [
            file([hunk(header: "@@ -1,1 +1,1 @@", [line(.addition, content, new: 1)])]),
        ]))

        XCTAssertEqual(document.text, "@@ -1,1 +1,1 @@\nfirst second third \n")
        XCTAssertEqual(document.lines.count, 2)
        let added = document.lines[1]
        // The substitution is 1:1 in UTF-16 units, so the recorded lengths hold
        // without recomputation and a highlight still matches the content range.
        XCTAssertEqual(added.range.length, content.utf16.count)
        XCTAssertEqual(text(document, added.contentRange), "first second third ")
        for (current, next) in zip(document.lines, document.lines.dropFirst()) {
            XCTAssertEqual(NSMaxRange(current.range) + 1, next.range.location)
        }
    }

    /// A CRLF pair inside the content is one Swift `Character` but two code
    /// units, so it must become two spaces — collapsing it to one would shorten
    /// the line and desynchronise every range after it.
    func testInteriorCRLFBecomesTwoSpaces() {
        let document = DiffDocument(diff: GitDiff(files: [
            file([hunk(header: "@@ -1,1 +1,1 @@", [line(.addition, "a\r\nb", new: 1)])]),
        ]))

        XCTAssertEqual(document.text, "@@ -1,1 +1,1 @@\na  b\n")
        XCTAssertEqual(document.lines[1].range.length, "a  b".utf16.count)
    }

    /// Ranges are UTF-16 units and the content is arbitrary source text, so a
    /// line of accents, emoji and arrows must round-trip exactly.
    func testNonASCIIContentRoundTripsThroughItsRanges() {
        let content = "héllo 👨‍👩‍👧 → ok"
        let document = DiffDocument(diff: GitDiff(files: [
            file([hunk([line(.addition, content, new: 1)])]),
        ]))

        let added = document.lines[1]
        XCTAssertEqual(text(document, added.contentRange), content)
        XCTAssertEqual(added.range.length, content.utf16.count)
    }

    // MARK: - Budgets

    func testPerFileCapHidesTheOverflowAndNotesIt() {
        let overflow = 25
        let lines = (1...DiffDocument.maxLinesPerFile + overflow).map {
            line(.addition, "l\($0)", new: $0)
        }
        let document = DiffDocument(diff: GitDiff(files: [file([hunk(lines)])]))

        let diffLines = document.lines.filter { $0.diffKind != nil }
        XCTAssertEqual(diffLines.count, DiffDocument.maxLinesPerFile)
        XCTAssertEqual(hiddenCounts(in: document), [overflow])
        XCTAssertEqual(document.lines.last?.kind, .note)
        XCTAssertEqual(
            text(document, document.lines.last!.range),
            "Diff too large \u{2014} \(overflow) more lines hidden")
    }

    /// The global budget exists so a many-file diff cannot make document
    /// construction unbounded even when every file stays under the per-file cap.
    func testGlobalBudgetStopsEmittingDiffLinesAcrossFiles() throws {
        let perFile = DiffDocument.maxLinesPerFile
        // Two files past what the budget holds. Every file supplies exactly the
        // per-file cap, so the budget runs out inside file
        // `maxTotalLines / perFile` and the last file gets no allowance at all —
        // which is the note-only rendering asserted below.
        let fileCount = DiffDocument.maxTotalLines / perFile + 2
        let files = (0..<fileCount).map { index in
            file(old: "f\(index).swift", new: "f\(index).swift",
                 [hunk((1...perFile).map { line(.addition, "l\($0)", new: $0) })])
        }
        let document = DiffDocument(diff: GitDiff(files: files))

        XCTAssertEqual(document.lines.filter { $0.diffKind != nil }.count,
                       DiffDocument.maxTotalLines)
        // Split across the notes of the files the budget ran out on, which
        // together account for everything the document did not emit.
        XCTAssertEqual(hiddenCounts(in: document).reduce(0, +),
                       fileCount * perFile - DiffDocument.maxTotalLines)
        // Every file is still present, so the sticky header and the file list
        // stay complete even when the tail renders as notes only.
        XCTAssertEqual(document.files.count, fileCount)
        XCTAssertEqual(document.files.last?.lineCount, 1)
        // The note reports the last file's own hidden count, not the document's:
        // it got no allowance, so all of its lines are hidden.
        let lastLine = try XCTUnwrap(document.lines.last)
        XCTAssertEqual(lastLine.kind, .note)
        XCTAssertEqual(text(document, lastLine.range),
                       "Diff too large \u{2014} \(perFile) more lines hidden")
    }

    /// Budget is spent hunk by hunk, so one file can hold a fully emitted hunk,
    /// a partially emitted one and a dropped one at once.
    func testPartiallyBudgetedHunkKeepsItsHeaderAndTheDroppedOneVanishes() {
        let fitting = DiffDocument.maxLinesPerFile - 10
        let hunks = [
            hunk(header: "@@ fitting @@", (1...fitting).map { line(.addition, "l\($0)", new: $0) }),
            hunk(header: "@@ partial @@", (1...50).map { (n: Int) in line(.addition, "p\(n)", new: n) }),
            hunk(header: "@@ dropped @@", (1...50).map { (n: Int) in line(.addition, "d\(n)", new: n) }),
        ]
        let document = DiffDocument(diff: GitDiff(files: [file(hunks)]))

        // The partially budgeted hunk keeps its header; the hunk left with no
        // budget contributes nothing at all, header included — a header on its
        // own would announce lines that never come.
        let headers = document.lines.filter { $0.kind == .hunkHeader }
        XCTAssertEqual(headers.map { text(document, $0.range) }, ["@@ fitting @@", "@@ partial @@"])
        XCTAssertEqual(document.lines.filter { $0.diffKind != nil }.count,
                       DiffDocument.maxLinesPerFile)
        XCTAssertEqual(hiddenCounts(in: document), [90])
    }

    // MARK: - Lookups

    func testSpansTileTheDocumentAndMapBackFromOffsets() {
        let document = DiffDocument(diff: GitDiff(files: [
            file(old: "a.swift", new: "a.swift", [hunk([line(.addition, "a", new: 1)])]),
            file(old: "b.swift", new: "b.swift", [hunk([line(.deletion, "b", old: 1)])]),
        ]))

        for (index, span) in document.lines.enumerated() {
            XCTAssertEqual(document.lineIndex(atCharacterOffset: span.range.location), index)
            XCTAssertEqual(document.lineIndex(atCharacterOffset: NSMaxRange(span.range) - 1), index)
        }
        XCTAssertEqual(document.fileIndex(withID: "b.swift"), 1)
        XCTAssertNil(document.fileIndex(withID: "nope.swift"))
        XCTAssertNil(document.lineIndex(atCharacterOffset: (document.text as NSString).length))
    }

    /// The sticky header and the scroll-to-file arithmetic both derive a file's
    /// vertical extent from its range, so the range must start exactly at the
    /// file's first paragraph and end exactly after its last one's terminator —
    /// not a character early, not a character into the next file.
    func testFileRangeCoversExactlyItsOwnLines() throws {
        let document = DiffDocument(diff: GitDiff(files: [
            file(old: "a.swift", new: "a.swift", [hunk([line(.addition, "a", new: 1)])]),
            file(old: "b.swift", new: "b.swift", [hunk([line(.deletion, "b", old: 1)])]),
        ]))

        for (index, span) in document.files.enumerated() {
            let owned = document.lines[span.firstLineIndex..<(span.firstLineIndex + span.lineCount)]
            let first = try XCTUnwrap(owned.first)
            let last = try XCTUnwrap(owned.last)
            XCTAssertTrue(owned.allSatisfy { $0.fileIndex == index })
            XCTAssertEqual(span.range.location, first.range.location)
            // `+ 1` for the last paragraph's terminator, which the file span
            // includes and the line span does not.
            XCTAssertEqual(NSMaxRange(span.range), NSMaxRange(last.range) + 1)
        }
        for (current, next) in zip(document.files, document.files.dropFirst()) {
            XCTAssertEqual(NSMaxRange(current.range), next.range.location)
        }
        let lastFile = try XCTUnwrap(document.files.last)
        XCTAssertEqual(NSMaxRange(lastFile.range), (document.text as NSString).length)
    }

    /// The renderer asks for a line index once per visible fragment, including at
    /// the very end of the document, so the search's edges are load-bearing.
    func testLineIndexAtTheDocumentsEdges() throws {
        let document = DiffDocument(diff: GitDiff(files: [
            file(old: "a.swift", new: "a.swift", [hunk([line(.addition, "a", new: 1)])]),
            file(old: "b.swift", new: "b.swift", [hunk([line(.deletion, "b", old: 1)])]),
        ]))
        let last = try XCTUnwrap(document.lines.last)

        // The final paragraph's terminator still belongs to that paragraph.
        XCTAssertEqual(document.lineIndex(atCharacterOffset: NSMaxRange(last.range)),
                       document.lines.count - 1)
        XCTAssertNil(document.lineIndex(atCharacterOffset: NSMaxRange(last.range) + 1))
        XCTAssertNil(document.lineIndex(atCharacterOffset: -1))
        XCTAssertNil(DiffDocument(diff: GitDiff(files: [])).lineIndex(atCharacterOffset: 0))
        // Paragraphs tile the text with no gaps, which is what lets the lookup be
        // a binary search over line starts.
        for (current, next) in zip(document.lines, document.lines.dropFirst()) {
            XCTAssertEqual(NSMaxRange(current.range) + 1, next.range.location)
        }
    }
}
