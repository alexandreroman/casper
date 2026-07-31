import AppKit
import CasperGit
import XCTest

@testable import CasperUI

/// These tests run a real TextKit 2 layout in-process. They pin the mapping
/// from laid-out geometry back to diff lines — the contract the background
/// fill, the gutter and the sticky header all read.
@MainActor
final class DiffFragmentGeometryTests: XCTestCase {
    private let width: CGFloat = 400

    // MARK: - Fixtures

    private func codeFile(named name: String, lines lineCount: Int) -> GitDiffFile {
        let lines = (1...lineCount).map {
            GitDiffLine(kind: .addition, content: "line \($0)", oldLineNumber: nil, newLineNumber: $0)
        }
        let hunk = GitDiffHunk(header: "@@ -1,\(lineCount) +1,\(lineCount) @@",
                               oldStart: 1, oldLines: lineCount,
                               newStart: 1, newLines: lineCount, lines: lines)
        return GitDiffFile(oldPath: name, newPath: name, status: .modified, isBinary: false, hunks: [hunk])
    }

    /// A file whose whole rendering is a single `.note` paragraph. `DiffDocument`
    /// guarantees these exist — a binary file, or one the line budget emptied —
    /// and they lay out in `DiffTextAssembly.noteFont`, not the code font.
    private func binaryFile(named name: String) -> GitDiffFile {
        GitDiffFile(oldPath: name, newPath: name, status: .modified, isBinary: true, hunks: [])
    }

    private func makeDocument(fileCount: Int, linesPerFile: Int) -> DiffDocument {
        DiffDocument(diff: GitDiff(files: (0..<fileCount).map {
            codeFile(named: "f\($0).swift", lines: linesPerFile)
        }))
    }

    /// A text view laid out at a fixed width, the way the surface hosts it.
    ///
    /// Every step here goes through the TextKit 2 API surface on purpose: merely
    /// *reading* `NSTextView.layoutManager` migrates the view to the TextKit 1
    /// stack and leaves `textLayoutManager` nil, so an `ensureLayout(for:)` on
    /// the compatibility layout manager would silently take the geometry under
    /// test out of the picture.
    ///
    /// Pass `layingOut: false` to leave the layout manager cold, which is what a
    /// test measuring how much layout a call *forces* needs.
    private func makeTextView(_ document: DiffDocument, layingOut: Bool = true) -> NSTextView {
        let storage = DiffTextAssembly.makeTextStorage(for: document)
        let textView = NSTextView(frame: CGRect(x: 0, y: 0, width: width, height: 10_000))
        textView.textContentStorage?.textStorage?.setAttributedString(storage)
        textView.textContainer?.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        // Laid out eagerly so the assertions below compare final geometry rather
        // than whatever the enumeration happened to force into existence.
        if layingOut, let layoutManager = textView.textLayoutManager {
            layoutManager.ensureLayout(for: layoutManager.documentRange)
        }
        return textView
    }

    private func makeGeometry(
        _ document: DiffDocument, layingOut: Bool = true
    ) throws -> DiffFragmentGeometry {
        let textView = makeTextView(document, layingOut: layingOut)
        let layoutManager = try XCTUnwrap(textView.textLayoutManager)
        return DiffFragmentGeometry(layoutManager: layoutManager, document: document)
    }

    /// How tall the whole document is once genuinely laid out, measured on a
    /// throwaway view. The bounded-layout tests below compare against this rather
    /// than against a literal, so they survive a font-metric change.
    private func fullLayoutHeight(of document: DiffDocument) throws -> CGFloat {
        let textView = makeTextView(document)
        return try XCTUnwrap(textView.textLayoutManager).usageBoundsForTextContainer.height
    }

    // MARK: - Fragment mapping

    func testEveryVisibleFragmentMapsToADiffLine() throws {
        let document = makeDocument(fileCount: 2, linesPerFile: 5)
        let geometry = try makeGeometry(document)

        let fragments = geometry.fragments(in: CGRect(x: 0, y: 0, width: width, height: 10_000))

        XCTAssertFalse(fragments.isEmpty)
        for fragment in fragments {
            XCTAssertTrue(document.lines.indices.contains(fragment.lineIndex))
            XCTAssertGreaterThan(fragment.rect.height, 0)
        }
        // Short lines never wrap, so each one contributes exactly one fragment
        // and every fragment starts its line.
        XCTAssertEqual(fragments.count, document.lines.count)
        XCTAssertTrue(fragments.allSatisfy(\.isLineStart))
        XCTAssertEqual(fragments.map(\.lineIndex), Array(document.lines.indices))
    }

    /// A line too long for the container wraps into several fragments, and only
    /// the first may print a gutter number.
    func testWrappedLineYieldsOneLineStartAndSeveralFragments() throws {
        let long = (1...80).map { "word\($0)" }.joined(separator: " ")
        let hunk = GitDiffHunk(header: "@@ -1,1 +1,1 @@", oldStart: 1, oldLines: 1,
                               newStart: 1, newLines: 1,
                               lines: [GitDiffLine(kind: .addition, content: long,
                                                   oldLineNumber: nil, newLineNumber: 1)])
        let document = DiffDocument(diff: GitDiff(files: [
            GitDiffFile(oldPath: "a.swift", newPath: "a.swift", status: .modified,
                        isBinary: false, hunks: [hunk]),
        ]))
        let geometry = try makeGeometry(document)

        let fragments = geometry.fragments(in: CGRect(x: 0, y: 0, width: width, height: 10_000))
            .filter { $0.lineIndex == 1 }

        XCTAssertGreaterThan(fragments.count, 1)
        XCTAssertEqual(fragments.filter(\.isLineStart).count, 1)
        XCTAssertTrue(fragments.first?.isLineStart == true)
    }

    func testFragmentsAreFilteredByTheRequestedRect() throws {
        let document = makeDocument(fileCount: 1, linesPerFile: 200)
        let geometry = try makeGeometry(document)

        let all = geometry.fragments(in: CGRect(x: 0, y: 0, width: width, height: 100_000))
        let window = geometry.fragments(in: CGRect(x: 0, y: 200, width: width, height: 100))

        XCTAssertLessThan(window.count, all.count)
        XCTAssertFalse(window.isEmpty)
        for fragment in window {
            XCTAssertTrue(fragment.rect.maxY > 200 && fragment.rect.minY < 300)
        }
    }

    /// The bounded enumeration is what lets this renderer hold a 20 000-line diff
    /// at all: `fragments(in:)` runs from `drawBackground(in:)` and from the ruler
    /// on every scroll notification, so it must lay out the requested rect and
    /// nothing else. Counting returned rows cannot show that — an implementation
    /// that enumerated the whole document and filtered afterwards would return the
    /// same rows — so the assertion is on how much layout the call forced.
    func testEnumerationLaysOutOnlyTheRequestedRect() throws {
        let document = makeDocument(fileCount: 1, linesPerFile: 2000)
        let fullHeight = try fullLayoutHeight(of: document)
        // Deliberately cold: what is under test is what this one call forces.
        let textView = makeTextView(document, layingOut: false)
        let layoutManager = try XCTUnwrap(textView.textLayoutManager)
        let geometry = DiffFragmentGeometry(layoutManager: layoutManager, document: document)
        let window = CGRect(x: 0, y: 0, width: width, height: 300)

        let fragments = geometry.fragments(in: window)
        let laidOut = layoutManager.usageBoundsForTextContainer.height

        XCTAssertFalse(fragments.isEmpty)
        // One rect's worth, with slack for the fragment the enumeration has to
        // reach before it can tell it is past `maxY`.
        XCTAssertLessThan(laidOut, window.height * 2)
        // And the document really is far taller than that bound, so the bound is
        // a bound rather than a coincidence of the fixture's size.
        XCTAssertGreaterThan(fullHeight, window.height * 20)
    }

    func testEmptyDocumentHasNoGeometry() throws {
        let document = DiffDocument(diff: GitDiff(files: []))
        let geometry = try makeGeometry(document)

        XCTAssertTrue(geometry.fragments(in: CGRect(x: 0, y: 0, width: width, height: 1000)).isEmpty)
        XCTAssertNil(geometry.top(ofFileAt: 0))
        XCTAssertNil(geometry.fileIndex(atY: 0))
        geometry.ensureLayout(throughFileAt: 0)  // must not trap on an absent file
    }

    /// A reserved header band and an inter-file gap are paragraph spacing, not
    /// rows, so nothing is reported inside them. That is what lets the row tint
    /// and the gutter stripe stop cleanly at a file boundary with no
    /// special-casing, and leaves the band to the sticky overlay alone.
    func testNoFragmentsInTheReservedBandOrTheInterFileGap() throws {
        let document = makeDocument(fileCount: 2, linesPerFile: 4)
        let geometry = try makeGeometry(document)
        let bandTop = try XCTUnwrap(geometry.top(ofFileAt: 1))

        let band = CGRect(x: 0, y: bandTop, width: width, height: DiffTextAssembly.headerBandHeight)
        let gap = CGRect(x: 0, y: bandTop - DiffTextAssembly.interFileGap,
                         width: width, height: DiffTextAssembly.interFileGap)

        XCTAssertTrue(geometry.fragments(in: band).isEmpty)
        XCTAssertTrue(geometry.fragments(in: gap).isEmpty)
    }

    func testNoFragmentsBelowTheLastRow() throws {
        let document = makeDocument(fileCount: 1, linesPerFile: 4)
        let textView = makeTextView(document)
        let layoutManager = try XCTUnwrap(textView.textLayoutManager)
        let geometry = DiffFragmentGeometry(layoutManager: layoutManager, document: document)
        let contentBottom = layoutManager.usageBoundsForTextContainer.maxY

        let below = geometry.fragments(
            in: CGRect(x: 0, y: contentBottom + 50, width: width, height: 200))

        XCTAssertTrue(below.isEmpty)
    }

    // MARK: - File tops

    func testFileTopsAscendAndRoundTripThroughFileIndexAtY() throws {
        let document = makeDocument(fileCount: 3, linesPerFile: 4)
        let geometry = try makeGeometry(document)

        let tops = try document.files.indices.map { try XCTUnwrap(geometry.top(ofFileAt: $0)) }

        XCTAssertEqual(tops, tops.sorted())
        for (index, top) in tops.enumerated() {
            XCTAssertEqual(geometry.fileIndex(atY: top + 1), index)
        }
    }

    func testTopIsNilForAnOutOfRangeFile() throws {
        let document = makeDocument(fileCount: 2, linesPerFile: 4)
        let geometry = try makeGeometry(document)

        XCTAssertNil(geometry.top(ofFileAt: -1))
        XCTAssertNil(geometry.top(ofFileAt: document.files.count))
    }

    /// The first file's band is the text view's `textContainerInset`, which sits
    /// *above* the container's origin — so its band top is negative, and it is
    /// measured by the same formula as every other file. Reporting the container
    /// origin instead would hand back the band's bottom, and a scroll to the first
    /// file would leave its bar painting over the file's first hunk header.
    func testFirstFilesBandTopSitsAboveTheContainerOrigin() throws {
        let document = makeDocument(fileCount: 2, linesPerFile: 4)
        let geometry = try makeGeometry(document)

        let top = try XCTUnwrap(geometry.top(ofFileAt: 0))

        XCTAssertEqual(top, -DiffTextAssembly.headerBandHeight, accuracy: 0.01)
    }

    /// `top(ofFileAt:)` probes the layout before forcing it, so a cold call and a
    /// warm one must agree. If the probe ever accepted a fragment TextKit had only
    /// estimated the position of, `casper diff <file>` would land off-target.
    func testFileTopIsTheSameColdAsWarm() throws {
        let document = makeDocument(fileCount: 30, linesPerFile: 20)
        let target = document.files.count - 1
        let cold = try makeGeometry(document, layingOut: false)
        let warm = try makeGeometry(document)

        let coldTop = try XCTUnwrap(cold.top(ofFileAt: target))
        let warmTop = try XCTUnwrap(warm.top(ofFileAt: target))

        XCTAssertEqual(coldTop, warmTop, accuracy: 0.5)
    }

    /// `warmTop(ofFileAt:)` is `top(ofFileAt:)` with the fallback taken away: the
    /// same answer for a file that is laid out, `nil` rather than a walk for one
    /// that is not. `DiffStickyHeader` walks its bands with it on every scroll
    /// notification and reads `nil` as "below the screen", so a variant that
    /// quietly forced layout, or one that disagreed with `top`, would each be a
    /// defect the overlay itself cannot show.
    func testWarmTopAnswersOnlyForFilesAlreadyLaidOut() throws {
        let document = makeDocument(fileCount: 30, linesPerFile: 20)
        let target = document.files.count - 1
        let coldView = makeTextView(document, layingOut: false)
        let coldLayoutManager = try XCTUnwrap(coldView.textLayoutManager)
        let cold = DiffFragmentGeometry(layoutManager: coldLayoutManager, document: document)
        let warm = try makeGeometry(document)
        let budget = try fullLayoutHeight(of: document) / 10

        XCTAssertNil(cold.warmTop(ofFileAt: target), "a cold file has no warm answer")
        XCTAssertLessThan(coldLayoutManager.usageBoundsForTextContainer.height, budget,
                          "and asking for one must not have laid the document out")

        XCTAssertEqual(try XCTUnwrap(warm.warmTop(ofFileAt: target)),
                       try XCTUnwrap(warm.top(ofFileAt: target)), accuracy: 0.01)
        XCTAssertNil(warm.warmTop(ofFileAt: document.files.count))
    }

    /// `top(ofFileAt:)` must answer from the layout it finds, not from an
    /// `ensureLayout` walk whose cost grows with how deep the file sits. Nothing
    /// else here would notice a regression: the walk changes no answer, it only
    /// costs. The surface calls this on every refresh, once per anchor, so a walk
    /// per call turns diff churn on a large document quadratic — and the
    /// per-scroll-notification path, which cannot afford a walk at any depth, is
    /// held to the stricter `warmTop(ofFileAt:)` instead.
    ///
    /// Stated as a ratio against a walk over the *same* layout manager rather
    /// than as a wall-clock budget, so what is pinned is the complexity and not
    /// the machine: a warm probe is three orders of magnitude cheaper than a
    /// walk, so twenty probes must still come in under one walk.
    func testWarmFileTopCostsFarLessThanALayoutWalk() throws {
        let document = makeDocument(fileCount: 100, linesPerFile: 100)
        let lastFile = document.files.count - 1
        let geometry = try makeGeometry(document)
        let clock = ContinuousClock()

        let oneWalk = clock.measure { geometry.ensureLayout(throughFileAt: lastFile) }
        let twentyProbes = clock.measure {
            for _ in 0..<20 { _ = geometry.top(ofFileAt: lastFile) }
        }

        XCTAssertLessThan(twentyProbes, oneWalk)
    }

    /// `ensureLayout(throughFileAt:)` stops at the target file's first paragraph.
    /// Nothing else in this suite would notice a regression to
    /// `ensureLayout(for: documentRange)`, which lays out the entire diff and is
    /// the cost every other decision here is arranged to avoid.
    func testEnsureLayoutStopsAtTheTargetFile() throws {
        let document = makeDocument(fileCount: 40, linesPerFile: 30)
        let fullHeight = try fullLayoutHeight(of: document)
        let textView = makeTextView(document, layingOut: false)
        let layoutManager = try XCTUnwrap(textView.textLayoutManager)
        let geometry = DiffFragmentGeometry(layoutManager: layoutManager, document: document)

        geometry.ensureLayout(throughFileAt: 1)
        let laidOut = layoutManager.usageBoundsForTextContainer.height

        XCTAssertGreaterThan(laidOut, 0, "the target file's own paragraph must be laid out")
        XCTAssertLessThan(laidOut, fullHeight / 10)
    }

    // MARK: - File ownership

    /// A file starts owning the viewport exactly where its reserved header band
    /// starts, not where its layout fragment does — TextKit folds the inter-file
    /// gap into the same paragraph spacing, so the fragment begins a gap's height
    /// above the band. If ownership flipped at the fragment instead, the sticky
    /// overlay would adopt the incoming file mid-push and its bar would jump.
    ///
    /// Checked at every boundary of every file, so an early, a middle and a late
    /// file are all covered: the answer must not depend on how deep in the
    /// document the boundary sits.
    func testFileOwnershipStartsAtTheReservedBandNotAtTheLayoutFragment() throws {
        let document = makeDocument(fileCount: 12, linesPerFile: 4)
        let geometry = try makeGeometry(document)
        // The gap really is a distinct region above the band, so the assertions
        // below test the correction rather than restate the band top.
        XCTAssertGreaterThan(DiffTextAssembly.interFileGap, 1)

        for index in document.files.indices.dropFirst() {
            let bandTop = try XCTUnwrap(geometry.top(ofFileAt: index))

            XCTAssertEqual(geometry.fileIndex(atY: bandTop), index, "band top of file \(index)")
            XCTAssertEqual(geometry.fileIndex(atY: bandTop - 1), index - 1, "1 pt above file \(index)")
            XCTAssertEqual(
                geometry.fileIndex(atY: bandTop - (DiffTextAssembly.interFileGap - 1)), index - 1,
                "inside the gap above file \(index)")
        }
    }

    /// A rubber-band overscroll hands over a negative `y`, and so does the first
    /// file's own band top. There is no geometry above the container's origin, so
    /// both resolve to the first file rather than to nothing.
    func testNegativeYBelongsToTheFirstFile() throws {
        let document = makeDocument(fileCount: 2, linesPerFile: 4)
        let geometry = try makeGeometry(document)

        XCTAssertEqual(geometry.fileIndex(atY: -100), 0)
        XCTAssertEqual(geometry.fileIndex(atY: try XCTUnwrap(geometry.top(ofFileAt: 0))), 0)
    }

    /// A file rendered as a single `.note` paragraph lays that paragraph out in
    /// the 10 pt `noteFont`, so its row height differs from every other test's
    /// here — a different way through the band arithmetic, on a file shape
    /// `DiffDocument` guarantees.
    func testNoteOnlyFileOwnsItsBandLikeAnyOther() throws {
        let document = DiffDocument(diff: GitDiff(files: [
            codeFile(named: "a.swift", lines: 4),
            binaryFile(named: "logo.png"),
        ]))
        let geometry = try makeGeometry(document)
        let noteFile = try XCTUnwrap(document.files.last)
        XCTAssertEqual(noteFile.lineCount, 1)

        let bandTop = try XCTUnwrap(geometry.top(ofFileAt: 1))

        XCTAssertEqual(geometry.fileIndex(atY: bandTop), 1)
        XCTAssertEqual(geometry.fileIndex(atY: bandTop - 1), 0)
        // Its one row lies below the band, and maps back to the note line.
        let rows = geometry.fragments(
            in: CGRect(x: 0, y: bandTop, width: width, height: DiffTextAssembly.headerBandHeight + 100))
        XCTAssertEqual(rows.map(\.lineIndex), [noteFile.firstLineIndex])
    }
}
