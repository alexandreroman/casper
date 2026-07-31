import AppKit
import CasperGit
import XCTest

@testable import CasperUI

/// What the diff view lets the reader select, and what a copy of it carries:
/// the text minus every line's `+`/`-`/space cue, which is rendering rather
/// than source.
///
/// Split three ways, the way the implementation is:
/// `DiffDocument.rangesExcludingCues(in:)` decides which characters are the
/// reader's and is pure; `DiffTextView.setSelectedRanges` narrows the highlight
/// to them; `DiffTextView.writeSelection` puts them on a pasteboard.
@MainActor
final class DiffCopyTests: XCTestCase {
    /// A line span grown over its paragraph terminator — what a whole-line
    /// selection piece covers, the `"\n"` belonging to the line it ends.
    private func withTerminator(_ range: NSRange) -> NSRange {
        NSRange(location: range.location, length: range.length + 1)
    }

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

    /// The text a copy of `selection` would produce, assembled the same way
    /// `DiffTextView` assembles it.
    private func copied(_ document: DiffDocument, _ selection: NSRange) -> String {
        let text = document.text as NSString
        return document.rangesExcludingCues(in: selection).map { text.substring(with: $0) }.joined()
    }

    /// A selection over the whole document.
    private func whole(_ document: DiffDocument) -> NSRange {
        NSRange(location: 0, length: (document.text as NSString).length)
    }

    // MARK: - Which characters survive

    /// The point of the whole exercise: a full-document copy pastes as code, not
    /// as a patch.
    func testCopyingEveryLineDropsEveryCue() {
        let document = document([
            line(.context, "let a = 1", old: 1, new: 1),
            line(.deletion, "let b = 2", old: 2),
            line(.addition, "let b = 3", new: 2),
        ])

        XCTAssertEqual(
            copied(document, whole(document)),
            """
            @@ -1,3 +1,3 @@
            let a = 1
            let b = 2
            let b = 3

            """)
    }

    /// A selection that starts after a line's cue has nothing to carve out of
    /// that line — only the *following* lines' cues go.
    func testSelectionStartingMidLineKeepsItsOwnLineWhole() {
        let document = document([
            line(.addition, "first", new: 1),
            line(.addition, "second", new: 2),
        ])
        let first = document.lines[1]
        let selection = NSRange(
            location: first.contentRange.location + 2,
            length: NSMaxRange(document.lines[2].range) - first.contentRange.location - 2)

        XCTAssertEqual(copied(document, selection), "rst\nsecond")
    }

    /// A selection ending inside a cue stops there rather than reaching past it
    /// and pulling in the line's first character.
    func testSelectionEndingInsideACueCopiesNothingPastIt() {
        let document = document([
            line(.addition, "first", new: 1),
            line(.addition, "second", new: 2),
        ])
        let second = document.lines[2]
        let selection = NSRange(
            location: document.lines[1].contentRange.location,
            length: second.contentRange.location - document.lines[1].contentRange.location)

        XCTAssertEqual(copied(document, selection), "first\n")
    }

    /// Selecting nothing but a cue copies nothing — there is no source character
    /// under it to fall back on.
    func testSelectingOnlyACueCopiesNothing() {
        let document = document([line(.addition, "added", new: 1)])
        let added = document.lines[1]
        let cue = NSRange(
            location: added.range.location,
            length: added.contentRange.location - added.range.location)

        XCTAssertEqual(document.rangesExcludingCues(in: cue), [])
        XCTAssertEqual(copied(document, cue), "")
    }

    func testEmptySelectionCopiesNothing() {
        let document = document([line(.addition, "added", new: 1)])

        XCTAssertEqual(document.rangesExcludingCues(in: NSRange(location: 3, length: 0)), [])
    }

    /// Hunk headers and notes carry no cue, so they come through verbatim — the
    /// carve-out is driven by `contentRange`, not by a per-kind special case.
    func testChromeLinesComeThroughVerbatim() {
        let document = DiffDocument(diff: GitDiff(files: [
            GitDiffFile(oldPath: "logo.png", newPath: "logo.png", status: .modified,
                        isBinary: true, hunks: []),
        ]))

        XCTAssertEqual(copied(document, whole(document)), "Binary file\n")
    }

    /// A truncated line keeps its marker: it is the only sign that what was
    /// copied is a prefix of the real line, so dropping it would produce a
    /// silently corrupt paste.
    func testTruncationMarkerSurvivesTheCopy() {
        let long = String(repeating: "x", count: DiffLineStyle.maxDisplayLineLength + 10)
        let document = document([line(.addition, long, new: 1)])
        let added = document.lines[1]

        XCTAssertTrue(added.truncated)
        XCTAssertEqual(
            copied(document, added.range),
            String(repeating: "x", count: DiffLineStyle.maxDisplayLineLength)
                + DiffDocument.truncationMarker)
    }

    /// A selection reaching past the document's last character has no line to
    /// read a cue from at its start, and is handed back untouched rather than
    /// dropped.
    func testSelectionBeyondTheDocumentIsKeptAsIs() {
        let document = document([line(.addition, "added", new: 1)])
        let length = (document.text as NSString).length
        let beyond = NSRange(location: length + 1, length: 4)

        XCTAssertEqual(document.rangesExcludingCues(in: beyond), [beyond])
    }

    // MARK: - What the highlight covers

    /// The visible promise: a selection over whole lines becomes one range per
    /// line, each starting at the code, so no band is ever drawn over a cue.
    func testSelectingWholeLinesHighlightsNoCue() {
        let document = document([
            line(.addition, "first", new: 1),
            line(.deletion, "second", old: 2),
        ])
        let textView = makeTextView(document)

        textView.setSelectedRange(whole(document))

        XCTAssertEqual(textView.selectedRanges.map(\.rangeValue), [
            withTerminator(document.lines[0].range),         // the hunk header, cueless
            withTerminator(document.lines[1].contentRange),  // "first", cue excluded
            withTerminator(document.lines[2].contentRange),  // "second", cue excluded
        ])
    }

    /// A plain click is a zero-length range and must survive untouched —
    /// carving one yields nothing, which would leave the reader unable to put the
    /// caret down at all.
    func testACaretIsLeftWhereItWasPut() {
        let document = document([line(.addition, "added", new: 1)])
        let textView = makeTextView(document)
        let caret = NSRange(location: document.lines[1].contentRange.location, length: 0)

        textView.setSelectedRange(caret)

        XCTAssertEqual(textView.selectedRanges.map(\.rangeValue), [caret])
    }

    /// Double-clicking the `+` selects it and nothing else — `NSTextView` sees a
    /// punctuation run. That collapses to a caret at the code's start rather than
    /// to no selection at all, which `NSTextView` does not allow.
    func testSelectingOnlyACueCollapsesToACaret() {
        let document = document([line(.addition, "added", new: 1)])
        let textView = makeTextView(document)
        let added = document.lines[1]
        let cue = NSRange(location: added.range.location,
                          length: added.contentRange.location - added.range.location)

        textView.setSelectedRange(cue)

        XCTAssertEqual(textView.selectedRanges.map(\.rangeValue),
                       [NSRange(location: added.contentRange.location, length: 0)])
    }

    /// AppKit hands the ranges it was given back through this same funnel on the
    /// next selection change, so carving an already-carved selection must be a
    /// no-op — otherwise a drag would eat a character per pass.
    func testCarvingAnAlreadyCarvedSelectionChangesNothing() {
        let document = document([
            line(.addition, "first", new: 1),
            line(.addition, "second", new: 2),
        ])
        let textView = makeTextView(document)
        textView.setSelectedRange(whole(document))
        let once = textView.selectedRanges.map(\.rangeValue)

        textView.selectedRanges = textView.selectedRanges

        XCTAssertEqual(textView.selectedRanges.map(\.rangeValue), once)
    }

    /// A view with no document yet cannot know where the cues are, and passes the
    /// selection straight through instead of guessing.
    func testSelectionIsUntouchedWithoutADocument() {
        let document = document([line(.addition, "added", new: 1)])
        let textView = makeTextView(document)
        textView.document = nil

        textView.setSelectedRange(whole(document))

        XCTAssertEqual(textView.selectedRanges.map(\.rangeValue), [whole(document)])
    }

    /// ⌘A on a big diff turns one range into thousands, and a selection must not
    /// be the thing that drags the whole document through TextKit: laying out
    /// 20 000 lines on the main thread is the freeze this renderer was built to
    /// avoid. Same probe as `DiffTextSurfaceTests`' viewport guard.
    func testSelectingAllOfABigDocumentLaysOutNothingBeyondTheViewport() throws {
        // Under `DiffDocument.maxLinesPerFile`, so every line really is emitted
        // and the range count below is exact.
        let lines = (1...2000).map { line(.addition, "line \($0)", new: $0) }
        let document = document(lines)
        let textView = makeTextView(document)
        let layoutManager = try XCTUnwrap(textView.textLayoutManager)
        // A viewport's worth of layout, forced the way a first draw would.
        DiffFragmentGeometry(layoutManager: layoutManager, document: document)
            .ensureLayout(in: CGRect(x: 0, y: 0, width: 400, height: 400))
        let laidOutBefore = layoutManager.usageBoundsForTextContainer.height

        textView.setSelectedRange(whole(document))

        XCTAssertEqual(textView.selectedRanges.count, lines.count + 1)
        XCTAssertEqual(layoutManager.usageBoundsForTextContainer.height, laidOutBefore,
                       "carving the selection forced layout of text nobody is looking at")
    }

    // MARK: - The pasteboard

    /// A pasteboard of our own, so a test never touches the developer's
    /// clipboard.
    private func makePasteboard(_ name: String) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("casper.tests.\(name)"))
        pasteboard.clearContents()
        return pasteboard
    }

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

    func testWritingTheSelectionStripsTheCues() throws {
        let document = document([
            line(.deletion, "let b = 2", old: 2),
            line(.addition, "let b = 3", new: 2),
        ])
        let textView = makeTextView(document)
        textView.setSelectedRange(whole(document))
        let pasteboard = makePasteboard("strip")

        XCTAssertTrue(textView.writeSelection(to: pasteboard, type: .string))
        XCTAssertEqual(pasteboard.string(forType: .string), """
            @@ -1,2 +1,2 @@
            let b = 2
            let b = 3

            """)
    }

    /// ⌘C goes through the *plural* `writeSelection(to:types:)`, handing it
    /// `writablePasteboardTypes`. Exercised here rather than through `copy(_:)`,
    /// which would write to the general pasteboard and clobber the developer's
    /// clipboard — this is the last call it makes before that.
    func testTheCopyPathWritesStrippedTextForEveryTypeItOffers() throws {
        let document = document([line(.addition, "added", new: 1)])
        let textView = makeTextView(document)
        textView.setSelectedRange(whole(document))
        let pasteboard = makePasteboard("copy-path")

        XCTAssertTrue(
            textView.writeSelection(to: pasteboard, types: textView.writablePasteboardTypes))
        XCTAssertEqual(pasteboard.string(forType: .string), "@@ -1,1 +1,1 @@\nadded\n")
        // Only plain text is on the board, so nothing a paste target might prefer
        // still carries the cue. `types` also lists the deprecated
        // `NSStringPboardType` alias for `.string`, which is the same bytes under
        // another name — hence a check for what must be *absent*.
        for rich: NSPasteboard.PasteboardType in [.rtf, .rtfd, .html] {
            XCTAssertNil(pasteboard.data(forType: rich), "\(rich.rawValue) should not be offered")
        }
    }

    /// A discontiguous (⌘-drag) selection is copied piece by piece, each piece
    /// stripped.
    func testDiscontiguousSelectionStripsEveryPiece() throws {
        let document = document([
            line(.addition, "first", new: 1),
            line(.addition, "second", new: 2),
        ])
        let textView = makeTextView(document)
        textView.selectedRanges = [document.lines[1].range, document.lines[2].range]
            .map { NSValue(range: $0) }
        let pasteboard = makePasteboard("discontiguous")

        XCTAssertTrue(textView.writeSelection(to: pasteboard, type: .string))
        XCTAssertEqual(pasteboard.string(forType: .string), "firstsecond")
    }

    /// Plain text is the only representation offered, so no paste target can
    /// reach for a richer one that still has the cues in it.
    func testOnlyPlainTextIsOffered() {
        XCTAssertEqual(makeTextView(document([line(.addition, "a", new: 1)])).writablePasteboardTypes,
                       [.string])
    }

    /// A view whose document does not match its storage refuses to slice by
    /// offsets that belong to another document: it falls back to a verbatim copy,
    /// cues and all. Wrong in a small, bounded way rather than in an arbitrary
    /// one.
    ///
    /// The selection is made while the view has *no* document, which is the only
    /// way to get an uncarved selection onto it — that is also the case the
    /// pasteboard guard exists for, a selection set before the document arrived.
    func testStorageDocumentMismatchFallsBackToAVerbatimCopy() {
        let rendered = document([line(.addition, "first", new: 1)])
        let textView = makeTextView(rendered)
        textView.document = nil
        textView.setSelectedRange(whole(rendered))
        textView.document = document([
            line(.addition, "first", new: 1),
            line(.addition, "second", new: 2),
        ])
        let pasteboard = makePasteboard("mismatch")

        XCTAssertTrue(textView.writeSelection(to: pasteboard, type: .string))
        XCTAssertEqual(pasteboard.string(forType: .string), rendered.text)
    }
}
