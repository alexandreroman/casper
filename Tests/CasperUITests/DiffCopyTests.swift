import AppKit
import CasperGit
import XCTest

@testable import CasperUI

/// What the diff view lets the reader select, and what a copy of it carries.
///
/// There is no cue-stripping anywhere: the `+`/`-` is not in the text storage at
/// all (`DiffGutterRuler` draws it), so a selection cannot reach one and a copy
/// cannot carry one. These tests pin that absence down, because it is what the
/// whole arrangement buys — and because the cue *was* in the text once, so
/// nothing about the current shape is self-evident.
@MainActor
final class DiffCopyTests: XCTestCase {
    // MARK: - Builders

    private func line(
        _ kind: GitDiffLine.Kind, _ content: String, old: Int? = nil, new: Int? = nil
    ) -> GitDiffLine {
        GitDiffLine(kind: kind, content: content, oldLineNumber: old, newLineNumber: new)
    }

    /// The header spells out the line count, so an expectation over the copied
    /// text can be written out in full without a magic constant in it.
    private func document(_ lines: [GitDiffLine]) -> DiffDocument {
        DiffDocument(diff: GitDiff(files: [
            GitDiffFile(
                oldPath: "a.swift", newPath: "a.swift", status: .modified, isBinary: false,
                hunks: [GitDiffHunk(
                    header: "@@ -1,\(lines.count) +1,\(lines.count) @@",
                    oldStart: 1, oldLines: lines.count,
                    newStart: 1, newLines: lines.count, lines: lines)]),
        ]))
    }

    /// A selection over the whole document.
    private func whole(_ document: DiffDocument) -> NSRange {
        NSRange(location: 0, length: (document.text as NSString).length)
    }

    // MARK: - The cue is not in the text

    /// The document reads as code, not as a patch. Which is also the alignment
    /// fix: with no cue in the paragraph, a wrapped line's first display row
    /// starts on the same character column as its later ones.
    func testTheTextCarriesNoCue() {
        let document = document([
            line(.context, "let a = 1", old: 1, new: 1),
            line(.deletion, "let b = 2", old: 2),
            line(.addition, "let b = 3", new: 2),
        ])

        XCTAssertEqual(document.text, """
            @@ -1,3 +1,3 @@
            let a = 1
            let b = 2
            let b = 3

            """)
    }

    /// The invariant behind the alignment, stated where it can regress: a code
    /// line's content starts at the paragraph's first character. Nothing sits in
    /// front of it to push its first display row sideways.
    ///
    /// This, rather than a geometry probe, is the honest test. TextKit already
    /// laid every display row's fragment out at the container's leading edge with
    /// the cue in the text too — what differed was that the *content* of the first
    /// row began one character in. So the character offsets are where the bug
    /// lived and where the guard belongs.
    func testEveryCodeLineStartsItsContentAtItsFirstCharacter() {
        let document = document([
            line(.context, "context", old: 1, new: 1),
            line(.deletion, "gone", old: 2),
            line(.addition, "added", new: 2),
        ])

        for line in document.lines where line.diffKind != nil {
            XCTAssertEqual(line.contentRange.location, line.range.location, "\(line.kind)")
            XCTAssertEqual(line.contentRange.length, line.range.length, "\(line.kind)")
        }
    }

    /// A truncated line is the one case where `contentRange` is shorter than
    /// `range`: the `… (line truncated)` marker is our commentary and stays
    /// outside it. The marker is still *in* the text, deliberately — it is the
    /// only sign that a copy of this line is a prefix of the real one.
    func testATruncatedLineKeepsItsMarkerInTheTextAndOutsideItsContent() {
        let long = String(repeating: "x", count: DiffLineStyle.maxDisplayLineLength + 10)
        let document = document([line(.addition, long, new: 1)])
        let added = document.lines[1]
        let text = document.text as NSString

        XCTAssertTrue(added.truncated)
        XCTAssertEqual(added.contentRange.location, added.range.location)
        XCTAssertEqual(text.substring(with: added.contentRange),
                       String(repeating: "x", count: DiffLineStyle.maxDisplayLineLength))
        XCTAssertEqual(text.substring(with: added.range),
                       String(repeating: "x", count: DiffLineStyle.maxDisplayLineLength)
                           + DiffDocument.truncationMarker)
    }

    // MARK: - Selection and copy

    /// A text view holding `document`, wired to a TextKit 2 stack the way the
    /// surface wires its own.
    private func makeTextView(_ document: DiffDocument) -> DiffTextView {
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        let container = NSTextContainer(
            size: CGSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        contentStorage.addTextLayoutManager(layoutManager)
        layoutManager.textContainer = container

        let textView = DiffTextView(frame: CGRect(x: 0, y: 0, width: 400, height: 400),
                                    textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        contentStorage.textStorage?.setAttributedString(
            DiffTextAssembly.makeTextStorage(for: document))
        textView.document = document
        return textView
    }

    /// One contiguous range, not the several a cue would have forced the view to
    /// carve the selection into. `NSTextView`'s own selection behaviour is left
    /// entirely alone, which is what keeps shift-click and shift-arrow extension
    /// working.
    func testSelectingEverythingIsOneUntouchedRange() {
        let document = document([
            line(.addition, "first", new: 1),
            line(.deletion, "second", old: 2),
        ])
        let textView = makeTextView(document)

        textView.setSelectedRange(whole(document))

        XCTAssertEqual(textView.selectedRanges.map(\.rangeValue), [whole(document)])
    }

    /// The end-to-end promise, through the pasteboard write ⌘C performs: what the
    /// reader gets is the code.
    func testCopyingTheSelectionYieldsCleanCode() throws {
        let document = document([
            line(.deletion, "let b = 2", old: 2),
            line(.addition, "let b = 3", new: 2),
        ])
        let textView = makeTextView(document)
        textView.setSelectedRange(whole(document))
        // A pasteboard of our own, so the test never touches the developer's
        // clipboard.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("casper.tests.diff-copy"))
        pasteboard.clearContents()

        XCTAssertTrue(
            textView.writeSelection(to: pasteboard, types: textView.writablePasteboardTypes))
        XCTAssertEqual(pasteboard.string(forType: .string), """
            @@ -1,2 +1,2 @@
            let b = 2
            let b = 3

            """)
    }
}
