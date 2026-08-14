import AppKit
import CasperGit
import SwiftUI
import XCTest

@testable import CasperUI

/// Surface-level smoke tests: the AppKit chain composes, the document reaches
/// every view, and the scroll/anchor arithmetic behaves.
///
/// These are NOT a layout-convergence guard. An automated convergence guard was
/// declined on 2026-07-30 in favour of live verification; nothing here detects a
/// non-converging layout, and a future reader must not mistake it for that.
@MainActor
final class DiffTextSurfaceTests: XCTestCase {
    private func makeDocument(fileCount: Int, linesPerFile: Int = 20) -> DiffDocument {
        let files = (0..<fileCount).map { index in
            let lines = (1...linesPerFile).map {
                GitDiffLine(kind: .addition, content: "line \($0)",
                            oldLineNumber: nil, newLineNumber: $0)
            }
            let hunk = GitDiffHunk(header: "@@ -1,\(linesPerFile) +1,\(linesPerFile) @@",
                                   oldStart: 1, oldLines: linesPerFile,
                                   newStart: 1, newLines: linesPerFile, lines: lines)
            return GitDiffFile(oldPath: "f\(index).swift", newPath: "f\(index).swift",
                               status: .modified, isBinary: false, hunks: [hunk])
        }
        return DiffDocument(diff: GitDiff(files: files))
    }

    /// The same shape as `makeDocument`, with content lines long enough to wrap
    /// several times at the hosted width.
    ///
    /// Wrapping is what makes TextKit's *estimated* height for a line it has not
    /// laid out diverge sharply from its real one — a single row against five — so
    /// a fixture built on it tells an estimate-derived position apart from a
    /// settled one by hundreds of points instead of by a rounding error.
    private func makeWrappingDocument(fileCount: Int, linesPerFile: Int) -> DiffDocument {
        let files = (0..<fileCount).map { index in
            let lines = (1...linesPerFile).map { lineNumber in
                GitDiffLine(kind: .addition,
                            content: "line \(lineNumber) " + String(repeating: "wrapping content ", count: 12),
                            oldLineNumber: nil, newLineNumber: lineNumber)
            }
            let hunk = GitDiffHunk(header: "@@ -1,\(linesPerFile) +1,\(linesPerFile) @@",
                                   oldStart: 1, oldLines: linesPerFile,
                                   newStart: 1, newLines: linesPerFile, lines: lines)
            return GitDiffFile(oldPath: "f\(index).swift", newPath: "f\(index).swift",
                               status: .modified, isBinary: false, hunks: [hunk])
        }
        return DiffDocument(diff: GitDiff(files: files))
    }

    /// A surface hosted at a realistic panel size, laid out once, taking its
    /// document the way `DiffSurfaceView` hands it over: as a property SwiftUI
    /// pushes when it realizes the representable. No imperative call is involved.
    private func makeHostedSurface(
        _ document: DiffDocument, highlights: [String: DiffFileHighlight] = [:]
    ) -> (controller: DiffSurfaceController, host: NSView) {
        let controller = DiffSurfaceController()
        let host = NSHostingView(
            rootView: DiffTextSurface(
                controller: controller,
                rendering: DiffRendering(revision: 1, document: document, highlights: highlights))
                .frame(width: 480, height: 600))
        host.frame = CGRect(x: 0, y: 0, width: 480, height: 600)
        host.layoutSubtreeIfNeeded()
        return (controller, host)
    }

    /// The scenario the whole property-based data flow exists for: the document is
    /// produced **before** the surface is realized, which is what every first load
    /// does — `DiffSurfaceView`'s body shows an empty state until the refresh
    /// finishes, so the representable only appears once a document already exists.
    ///
    /// Realizing the surface must therefore be enough on its own. Nothing here
    /// calls the coordinator, and nothing here relies on `.onAppear` running after
    /// `makeCoordinator()` — an ordering SwiftUI does not document.
    func testRealizingTheSurfaceRendersADocumentThatAlreadyExists() throws {
        let document = makeDocument(fileCount: 3)
        let controller = DiffSurfaceController()
        let host = NSHostingView(
            rootView: DiffTextSurface(
                controller: controller,
                rendering: DiffRendering(revision: 1, document: document, highlights: [:]))
                .frame(width: 480, height: 600))
        host.frame = CGRect(x: 0, y: 0, width: 480, height: 600)

        host.layoutSubtreeIfNeeded()

        let coordinator = try XCTUnwrap(controller.coordinator)
        XCTAssertEqual(coordinator.textView.string, document.text)
        XCTAssertEqual(coordinator.appliedRevision, 1)
    }

    /// A refresh reaches the surface the same way, and the reader keeps their
    /// place across it: the swap reads the anchor off the live surface itself, so
    /// no caller has to remember to.
    func testAnUpdateSwapsTheDocumentAndKeepsTheReadersPlace() throws {
        let controller = DiffSurfaceController()
        let host = NSHostingView(
            rootView: DiffTextSurface(
                controller: controller,
                rendering: DiffRendering(revision: 1, document: makeDocument(fileCount: 4, linesPerFile: 40),
                                         highlights: [:]))
                .frame(width: 480, height: 600))
        host.frame = CGRect(x: 0, y: 0, width: 480, height: 600)
        host.layoutSubtreeIfNeeded()
        let coordinator = try XCTUnwrap(controller.coordinator)
        coordinator.scroll(toFileID: "f2.swift")

        let refreshed = makeDocument(fileCount: 4, linesPerFile: 41)
        host.rootView = DiffTextSurface(
            controller: controller,
            rendering: DiffRendering(revision: 2, document: refreshed, highlights: [:]))
            .frame(width: 480, height: 600)
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(coordinator.appliedRevision, 2)
        XCTAssertEqual(coordinator.textView.string, refreshed.text)
        XCTAssertEqual(coordinator.currentAnchor()?.fileID, "f2.swift")
    }

    /// Highlights carried over from the previous diff have to be repainted after a
    /// swap: `DiffTextAssembly` builds the fresh storage from base attributes only,
    /// and the files they belong to are deliberately not re-highlighted.
    func testCarriedHighlightsArePaintedOntoTheFreshStorage() throws {
        let document = makeDocument(fileCount: 1, linesPerFile: 3)
        let carried = (1...3).map { index -> AttributedString in
            var line = AttributedString("line \(index)")
            line.foregroundColor = .purple
            return line
        }

        let (controller, _) = makeHostedSurface(
            document, highlights: ["f0.swift": DiffFileHighlight(new: carried, old: nil)])

        let coordinator = try XCTUnwrap(controller.coordinator)
        let span = document.lines[1]
        let color = coordinator.textView.textStorage?
            .attribute(.foregroundColor, at: span.contentRange.location, effectiveRange: nil)
        XCTAssertEqual(color as? NSColor, NSColor(Color.purple))
    }

    /// The order the carried highlights are painted in, which is a performance
    /// invariant and not a cosmetic one: `NSTextStorage` holds its attributes in a
    /// run-length array, so painting a mid-document file memmoves every run below
    /// it. Ascending order appends and stays linear; the arbitrary order of
    /// `DiffRendering.highlights` itself is quadratic, and froze the main thread
    /// for minutes on a large diff.
    ///
    /// The order is unobservable in the finished storage — `applyHighlight` is
    /// idempotent and its output order-independent — so this asserts on the pure
    /// accessor `render(_:)` consumes. Fourteen files, because that is what makes a
    /// Dictionary's hash order essentially never document order by accident.
    func testCarriedHighlightsArePaintedInDocumentOrder() throws {
        let document = makeDocument(fileCount: 14, linesPerFile: 2)
        // Two files left unhighlighted — highlighting is progressive, so a swap
        // routinely carries over fewer files than the diff has — plus one naming a
        // file that has left the diff, which is what a highlight finishing just
        // after a refresh looks like.
        let highlighted = document.files.map(\.id).filter { $0 != "f3.swift" && $0 != "f11.swift" }
        var highlights = Dictionary(
            uniqueKeysWithValues: highlighted.map { ($0, DiffFileHighlight(new: nil, old: nil)) })
        highlights["gone.swift"] = DiffFileHighlight(new: nil, old: nil)

        let ordered = DiffRendering(revision: 1, document: document, highlights: highlights)
            .highlightsInDocumentOrder

        let indices = ordered.map(\.fileIndex)
        XCTAssertEqual(indices, indices.sorted(), "highlights must be painted in ascending file order")
        XCTAssertEqual(Set(indices).count, indices.count, "no file is painted twice")
        XCTAssertEqual(indices, Array(0..<14).filter { $0 != 3 && $0 != 11 },
                       "every highlighted file, only the highlighted ones, and no stale ID")
        // Without this the fixture could pass while `render(_:)` iterated the
        // dictionary: it is only a regression test if the hash order it must not
        // use differs from the document's.
        XCTAssertNotEqual(highlights.keys.compactMap { document.fileIndex(withID: $0) }, indices,
                          "the fixture no longer discriminates hash order from document order")
    }

    /// Painting through the accessor still colors the text, so the ordering above
    /// is not bought by dropping the highlights on the floor. Order-independent by
    /// construction: what it checks is that every file named got painted.
    func testHighlightsPaintedInDocumentOrderStillReachEveryFile() throws {
        let document = makeDocument(fileCount: 14, linesPerFile: 2)
        let purpleLines = (1...2).map { index -> AttributedString in
            var line = AttributedString("line \(index)")
            line.foregroundColor = .purple
            return line
        }
        let highlights = Dictionary(
            uniqueKeysWithValues: document.files.map {
                ($0.id, DiffFileHighlight(new: purpleLines, old: nil))
            })

        let (controller, _) = makeHostedSurface(document, highlights: highlights)

        let storage = try XCTUnwrap(controller.coordinator?.textView.textStorage)
        // Every source line, skipping the chrome ones (hunk headers) that have no
        // syntax to color.
        let sourceLines = document.lines.filter { $0.diffKind != nil }
        XCTAssertEqual(Set(sourceLines.map(\.fileIndex)).count, document.files.count,
                       "the fixture must put colorable lines in every file")
        for line in sourceLines {
            let color = storage.attribute(
                .foregroundColor, at: line.contentRange.location, effectiveRange: nil)
            XCTAssertEqual(color as? NSColor, NSColor(Color.purple),
                           "file \(line.fileIndex) went unpainted")
        }
    }

    func testSurfaceComposesAndTakesTheDocument() throws {
        let document = makeDocument(fileCount: 3)
        let (controller, _) = makeHostedSurface(document)
        let coordinator = try XCTUnwrap(controller.coordinator)

        XCTAssertEqual(coordinator.textView.document, document)
        XCTAssertEqual(coordinator.gutter.document, document)
        XCTAssertEqual(coordinator.stickyHeader.document, document)
        XCTAssertEqual(coordinator.textView.string, document.text)
        XCTAssertNotNil(coordinator.textView.textLayoutManager, "the TextKit 2 chain must be explicit")
        // The first file's reserved band *is* this inset — nothing in the text
        // flow reserves it, since TextKit ignores `paragraphSpacingBefore` on the
        // document's first paragraph.
        XCTAssertEqual(coordinator.textView.textContainerInset.height, DiffTextAssembly.headerBandHeight)
    }

    /// Selection and copy are a goal of this work, so the view must be
    /// selectable and not editable.
    func testTextIsSelectableButNotEditable() throws {
        let (controller, _) = makeHostedSurface(makeDocument(fileCount: 1))
        let textView = try XCTUnwrap(controller.coordinator?.textView)

        XCTAssertTrue(textView.isSelectable)
        XCTAssertFalse(textView.isEditable)
    }

    /// Copy must yield clean code: gutter numbers live in the ruler, so they can
    /// never enter the pasteboard, and the reserved header band is spacing
    /// rather than characters.
    func testCopiedTextCarriesNoGutterNumbersOrBlankBandLines() throws {
        let document = makeDocument(fileCount: 2, linesPerFile: 3)
        let (controller, _) = makeHostedSurface(document)
        let textView = try XCTUnwrap(controller.coordinator?.textView)

        textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))
        let copied = textView.attributedSubstring(forProposedRange: textView.selectedRange(),
                                                  actualRange: nil)?.string
        // `dropLast()` drops the empty component past the document's final
        // paragraph terminator — that terminator, not a reserved band.
        let lines = try XCTUnwrap(copied).split(separator: "\n", omittingEmptySubsequences: false).dropLast()

        XCTAssertFalse(lines.isEmpty)
        XCTAssertFalse(lines.contains(""), "a reserved band must not copy as an empty line")
        for line in lines where line.hasPrefix("+") {
            XCTAssertEqual(String(line.dropFirst()).prefix(4), "line")
        }
    }

    func testScrollToFileMovesTheClipViewToThatFile() throws {
        let document = makeDocument(fileCount: 4, linesPerFile: 40)
        let (controller, _) = makeHostedSurface(document)
        let coordinator = try XCTUnwrap(controller.coordinator)

        XCTAssertTrue(coordinator.scroll(toFileID: "f3.swift"))

        XCTAssertEqual(coordinator.currentAnchor()?.fileID, "f3.swift")
        XCTAssertGreaterThan(coordinator.clipView.bounds.origin.y, 0)
    }

    /// A refresh must not throw the reader back to the top: the anchor is read
    /// before the swap and restored after it.
    func testAnchorSurvivesADocumentSwap() throws {
        let document = makeDocument(fileCount: 4, linesPerFile: 40)
        let (controller, host) = makeHostedSurface(document)
        let coordinator = try XCTUnwrap(controller.coordinator)
        coordinator.scroll(toFileID: "f2.swift")
        let anchor = try XCTUnwrap(coordinator.currentAnchor())

        coordinator.apply(document: makeDocument(fileCount: 4, linesPerFile: 41), restoring: anchor)
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(coordinator.currentAnchor()?.fileID, "f2.swift")
    }

    func testAnchorFallsBackToTheTopWhenItsFileLeavesTheDiff() throws {
        let (controller, host) = makeHostedSurface(makeDocument(fileCount: 4, linesPerFile: 40))
        let coordinator = try XCTUnwrap(controller.coordinator)
        coordinator.scroll(toFileID: "f3.swift")

        coordinator.apply(document: makeDocument(fileCount: 1, linesPerFile: 5),
                          restoring: DiffScrollAnchor(fileID: "f3.swift", offsetInFile: 10))
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(coordinator.clipView.bounds.origin.y, 0, accuracy: 0.5)
    }

    func testHighlightReachesTheStorageWithoutChangingTheText() throws {
        let document = makeDocument(fileCount: 1, linesPerFile: 3)
        let (controller, _) = makeHostedSurface(document)
        let coordinator = try XCTUnwrap(controller.coordinator)
        let highlighted = (1...3).map { index -> AttributedString in
            var line = AttributedString("line \(index)")
            line.foregroundColor = .purple
            return line
        }

        coordinator.applyHighlight(DiffFileHighlight(new: highlighted, old: nil),
                                   forFileID: "f0.swift")

        XCTAssertEqual(coordinator.textView.string, document.text)
        let span = document.lines[1]
        let color = coordinator.textView.textStorage?
            .attribute(.foregroundColor, at: span.contentRange.location, effectiveRange: nil)
        XCTAssertEqual(color as? NSColor, NSColor(Color.purple))
    }

    /// An unknown file is reported rather than mistaken for a scroll that landed:
    /// `DiffSurfaceView` keys "apply this target later" off exactly that, so a
    /// target naming a file only the next diff has isn't swallowed.
    func testUnknownFileIDsAreIgnored() throws {
        let (controller, _) = makeHostedSurface(makeDocument(fileCount: 1))
        let coordinator = try XCTUnwrap(controller.coordinator)
        let before = coordinator.clipView.bounds.origin.y

        XCTAssertFalse(coordinator.scroll(toFileID: "nope.swift"))
        coordinator.applyHighlight(DiffFileHighlight(new: nil, old: nil), forFileID: "nope.swift")

        XCTAssertEqual(coordinator.clipView.bounds.origin.y, before, accuracy: 0.5)
    }

    // MARK: - The pinned bar

    /// The bar's drawn height is what the blank band in the text flow is sized
    /// for, so the two have to be the same number: a taller bar covers the file's
    /// first line, a shorter one leaves a strip of scrolling content above it.
    /// Asserting `paragraphSpacingBefore == headerBandHeight + interFileGap` in the
    /// assembly is a tautology that cannot catch either.
    func testThePinnedBarDrawsExactlyTheReservedBandHeight() throws {
        let (controller, _) = makeHostedSurface(makeDocument(fileCount: 3, linesPerFile: 40))
        let coordinator = try XCTUnwrap(controller.coordinator)

        // Parked at the top, so the first file's bar is pinned and nothing pushes.
        XCTAssertEqual(coordinator.stickyHeader.bars.map(\.fileIndex), [0])
        let bands = try HeaderProbe(coordinator.stickyHeader).paintedBands
        XCTAssertEqual(bands.count, 1, "one bar, one painted strip")
        let bar = try XCTUnwrap(bands.first)
        XCTAssertEqual(bar.lowerBound, 0, accuracy: 1, "the pinned bar hugs the viewport's top edge")
        XCTAssertEqual(bar.upperBound - bar.lowerBound, DiffTextAssembly.headerBandHeight, accuracy: 1)
    }

    /// The push, which is the one piece of arithmetic this overlay does: with the
    /// next file's band `d` below the top edge and `d` under a band height, the
    /// outgoing bar slides up to `d - headerBandHeight` and the incoming one draws
    /// at `d`. Read back off the overlay's own pixels, since it is drawing code.
    func testTheIncomingFilePushesTheOutgoingBarOut() throws {
        let (controller, _) = makeHostedSurface(makeDocument(fileCount: 3, linesPerFile: 40))
        let coordinator = try XCTUnwrap(controller.coordinator)
        let band = DiffTextAssembly.headerBandHeight
        let distance = (band / 2).rounded()

        try scroll(coordinator, soThatFileAt: 1, sitsBelowTheTopEdgeBy: distance)

        let bars = coordinator.stickyHeader.bars
        XCTAssertEqual(bars.map(\.fileIndex), [0, 1],
                       "the outgoing file keeps a bar while it is being pushed out")
        XCTAssertEqual(try XCTUnwrap(bars.first).y, distance - band, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(bars.dropFirst().first).y, distance, accuracy: 1)

        // The two bars meet, so they paint one contiguous strip — the outgoing one
        // clipped at the top edge. Where that strip ends is the incoming bar's own
        // bottom edge, and the hairline inside it is where the two meet.
        let probe = try HeaderProbe(coordinator.stickyHeader)
        let strip = try XCTUnwrap(probe.paintedBands.first)
        XCTAssertEqual(probe.paintedBands.count, 1)
        XCTAssertEqual(strip.lowerBound, 0, accuracy: 1)
        XCTAssertEqual(strip.upperBound, distance + band, accuracy: 1)
        XCTAssertGreaterThan(
            channelDistance(probe.color(atY: distance - 0.5), probe.color(atY: distance / 2)), 0.03,
            "the outgoing bar's bottom hairline marks where the incoming one starts")
    }

    /// A file's bar lives in that file's own reserved band and travels up the
    /// viewport with it, exactly as an in-flow section header does, until the band
    /// reaches the top edge and the bar comes to rest there. Mid-viewport it shares
    /// the screen with the pinned bar of the file above — two bars at once, neither
    /// clipped nor doubled, which is what pinned sections show today.
    func testAFileBarRidesUpInsideItsOwnBandUntilItPins() throws {
        let (controller, _) = makeHostedSurface(makeDocument(fileCount: 3, linesPerFile: 40))
        let coordinator = try XCTUnwrap(controller.coordinator)
        let band = DiffTextAssembly.headerBandHeight

        for distance in [CGFloat(300), 120] {
            try scroll(coordinator, soThatFileAt: 1, sitsBelowTheTopEdgeBy: distance)

            let bars = coordinator.stickyHeader.bars
            XCTAssertEqual(bars.map(\.fileIndex), [0, 1],
                           "the pinned file and the one band on screen, at \(distance)")
            // Unwrapped rather than subscripted, so a regression that drops a bar
            // fails here instead of trapping.
            let pinned = try XCTUnwrap(bars.first)
            let riding = try XCTUnwrap(bars.dropFirst().first)
            XCTAssertEqual(pinned.y, 0, accuracy: 0.5, "nothing overlaps the pinned bar yet")
            XCTAssertEqual(riding.y, distance, accuracy: 1, "the bar sits in its own band")

            // Two separate strips, each exactly one band tall: the pinned bar is not
            // stretched down to meet the other, and the band's bar is drawn whole.
            let strips = try HeaderProbe(coordinator.stickyHeader).paintedBands
            XCTAssertEqual(strips.count, 2, "two bars on screen at \(distance)")
            XCTAssertEqual(strips[0].lowerBound, 0, accuracy: 1)
            XCTAssertEqual(strips[0].upperBound, band, accuracy: 1)
            XCTAssertEqual(strips[1].lowerBound, distance, accuracy: 1)
            XCTAssertEqual(strips[1].upperBound, distance + band, accuracy: 1)
        }
    }

    /// Every band the viewport shows carries a bar, and no file below it does. With
    /// one-line files several bands share the screen at once, which is where "one
    /// bar per visible band" is a different statement from "one bar, maybe two".
    func testEveryBandOnScreenCarriesItsOwnBar() throws {
        let document = makeDocument(fileCount: 12, linesPerFile: 1)
        let (controller, _) = makeHostedSurface(document)
        let coordinator = try XCTUnwrap(controller.coordinator)
        let geometry = try XCTUnwrap(coordinator.geometry)
        let viewportHeight = coordinator.clipView.bounds.height

        let bars = coordinator.stickyHeader.bars
        XCTAssertGreaterThan(bars.count, 3, "the fixture must put several bands on screen")
        XCTAssertEqual(bars.map(\.fileIndex), Array(0..<bars.count),
                       "consecutive files in document order, each once")
        XCTAssertEqual(try XCTUnwrap(bars.first).y, 0, accuracy: 0.5,
                       "the first file's bar is the pinned one")
        for bar in bars.dropFirst() {
            XCTAssertGreaterThan(bar.y, 0)
            XCTAssertLessThan(bar.y, viewportHeight)
        }
        XCTAssertTrue(zip(bars, bars.dropFirst()).allSatisfy { $0.y < $1.y }, "in screen order")
        // The first file left without a bar is the first one whose band starts below
        // the viewport, so the run of bars stops exactly where the screen does.
        let firstWithoutABar = try XCTUnwrap(geometry.top(ofFileAt: bars.count)) - visibleTop(of: coordinator)
        XCTAssertGreaterThanOrEqual(firstWithoutABar, viewportHeight)
    }

    /// Resolving the bars must force no layout. The overlay runs off a scroll
    /// bounds-change notification, several times per frame under momentum
    /// scrolling, and the forcing `top(ofFileAt:)` walks from the document's start
    /// whenever the file it is handed is cold — 11 ms deep into a 20 000-line diff,
    /// the very cost this renderer exists to remove. The band that *ends* the walk
    /// is the one most likely to be cold, so a forcing accessor regresses this path
    /// first.
    ///
    /// **The cold window is real and recurring.** A hosted `NSTextView` is
    /// vertically resizable, so it has to know its own height and lays the whole
    /// document out at its next layout pass — but a document swap invalidates that,
    /// and until the following frame everything past the viewport is cold again.
    /// Casper recomputes the diff on every file change, so a reader scrolling an
    /// actively-edited worktree sits in that window continuously; the fixture
    /// therefore stops right where a refresh leaves the surface.
    ///
    /// Two long files, so the first band below the viewport is a whole file away
    /// and a walk to it has to lay out everything in between. Pinned as laid-out
    /// height against the viewport's own height, because what must hold is that the
    /// document's tail stays untouched — a wall-clock budget would pin this machine
    /// instead.
    func testResolvingTheBarsLaysOutNothingBeyondTheViewport() throws {
        // Hosted on a trivial document and then swapped, with no layout pass after
        // the swap: exactly where a refresh leaves the surface.
        let (controller, _) = makeHostedSurface(makeDocument(fileCount: 1, linesPerFile: 1))
        let coordinator = try XCTUnwrap(controller.coordinator)
        coordinator.apply(document: makeDocument(fileCount: 2, linesPerFile: 1500), restoring: nil)
        let layoutManager = try XCTUnwrap(coordinator.textView.textLayoutManager)
        let viewportHeight = coordinator.clipView.bounds.height
        // Enough for the viewport and for TextKit overshooting it by a row or two,
        // and still two orders of magnitude short of the whole document.
        let budget = 2 * viewportHeight

        XCTAssertLessThan(layoutManager.usageBoundsForTextContainer.height, budget,
                          "applying the document resolved the bars over layout it forced itself")

        coordinator.stickyHeader.update(
            geometry: coordinator.geometry, visibleTop: visibleTop(of: coordinator),
            visibleHeight: viewportHeight)

        XCTAssertLessThan(layoutManager.usageBoundsForTextContainer.height, budget,
                          "resolving the bars laid out text the viewport does not show")
        // The guard is worth nothing if the bars came out empty: the walk has to
        // reach the second file's band and find it below the screen, not be stopped
        // by an overlay that resolved no file at all.
        XCTAssertEqual(coordinator.stickyHeader.bars.map(\.fileIndex), [0])
    }

    /// Every bar must sit on the band the text view actually draws, once TextKit's
    /// layout has settled after a refresh — with no scroll to shake them loose.
    ///
    /// TextKit answers with *estimated* heights for content it has not laid out, and
    /// a refresh leaves the whole document cold: the swap resolves the bars over the
    /// positions those estimates produce, and the carried highlights painted straight
    /// afterwards invalidate that layout again. The text view's next layout pass
    /// re-lays the viewport out — at *different* positions, because the estimates
    /// behind them are not the ones the first pass used — and every piece of chrome
    /// that reads `DiffFragmentGeometry` at draw time follows the text there: the row
    /// tints, the gutter's numbers and stripes. The bars are a cache, so without a
    /// trigger for "layout has settled" they stay where the swap put them, and the
    /// reader sees a bar stranded in the previous file's code with its own band left
    /// blank — healing on the next scroll, which is the notification that finally
    /// re-resolves them.
    ///
    /// **What the bars are held against is where the text is drawn**, read through
    /// the same `fragments(in:)` call `DiffTextView.drawBackground(in:)` makes. Not
    /// through the forcing `top(ofFileAt:)`: that lays the document out on the spot
    /// and answers with a position nothing on screen is using, which makes a stale
    /// bar look wrong when it is merely early — and, worse, makes a correct bar look
    /// wrong too.
    ///
    /// The settling happens through a view layout pass, the way the app reaches it,
    /// rather than through an `NSTextLayoutManager.ensureLayout` call the app never
    /// makes.
    ///
    /// **Three hundred files of three wrapping lines, read 150 files deep, and the
    /// refresh brings a 301st** — many short files rather than a few tall ones, because
    /// the fixture must not depend on *which* part of the document the viewport lands
    /// in. TextKit's estimated heights are platform-dependent: for the identical
    /// pre-swap layout, the estimated document measures 87 910 pt on macOS 15 against
    /// 77 243 pt on macOS 26, so the container `y` the clip view is parked at maps to
    /// content thousands of points apart once the swap has left the layout cold. A
    /// fixture asking for one file boundary inside a 600 pt window fails that lottery
    /// on the OS it was not measured on — while with every file shorter than the
    /// viewport, *any* window holds a boundary wherever it lands, so the bands this
    /// needs exist by construction. Depth is the other half: the drawn positions rest
    /// on the estimated pitch of every file above the viewport, so the gap between an
    /// estimate-derived position and a settled one grows with the offset — 150 files
    /// in, at a real pitch of 312 pt against an estimated 266, that is ~6 900 pt.
    /// Measured with the settled-layout trigger removed, the bars name files 149 to 151
    /// while the viewport draws file 176's band: every bar on a file that is nowhere on
    /// screen.
    ///
    /// The refresh appends its file rather than growing every file by a line, so that
    /// nothing *above* the reader changes size. The anchor then restores to the same
    /// container `y`, which is what leaves TextKit's estimates as the only thing that
    /// moves — a fixture whose reader lands somewhere else after the swap tests the
    /// clip view's clamping arithmetic instead, and re-resolves the bars off the
    /// scroll notification it triggers, which is the trigger this test must not lean
    /// on. The swap still invalidates the whole layout, and the carried highlights
    /// invalidate it again per file.
    ///
    /// Only the bands sitting comfortably inside the viewport are held against the
    /// bars, and that is the two bounds agreeing rather than a loosening. The overlay
    /// emits a bar for every band *top* above the bottom edge, while a band whose first
    /// row falls past that edge is not drawn at all — routine now that a boundary comes
    /// every 312 pt, and the trailing bar of this very fixture. Keeping the bands whose
    /// first row is fully on screen is where both bounds agree, and where the settle
    /// pass has certainly laid that row out.
    func testEveryBarSitsOnTheBandTheTextDrawsAfterARefresh() throws {
        let controller = DiffSurfaceController()
        let initial = makeWrappingDocument(fileCount: 300, linesPerFile: 3)
        let host = NSHostingView(rootView: hostedSurface(controller, revision: 1, document: initial))
        host.frame = CGRect(x: 0, y: 0, width: 480, height: 600)
        host.layoutSubtreeIfNeeded()
        let coordinator = try XCTUnwrap(controller.coordinator)
        // Deep in the document, which is where a refresh strands the bars: parked at
        // the top there is nothing above the viewport for an estimate to be wrong about.
        try scroll(coordinator, soThatFileAt: 150, sitsBelowTheTopEdgeBy: 200)

        // Carrying the previous diff's highlights, as every Casper refresh does: they
        // are painted right after the swap has resolved the bars, and the edits
        // invalidate the very layout those bars were resolved over.
        let refreshed = makeWrappingDocument(fileCount: 301, linesPerFile: 3)
        host.rootView = hostedSurface(
            controller, revision: 2, document: refreshed,
            highlights: makeWrappingHighlights(for: refreshed, linesPerFile: 3))
        // One layout pass, which is all a refresh gets: SwiftUI pushes the document in
        // `updateNSView` and the text view lays itself out in the same pass.
        host.layoutSubtreeIfNeeded()
        drainPendingBarUpdates()

        let geometry = try XCTUnwrap(coordinator.geometry)
        let viewportHeight = coordinator.clipView.bounds.height
        let current = try XCTUnwrap(geometry.fileIndex(atY: visibleTop(of: coordinator)))
        let bars = coordinator.stickyHeader.bars
        let bands = try drawnBands(in: coordinator, document: refreshed).filter {
            // The set the overlay's own bands are drawn from: the file owning the top
            // edge is described by the pinned bar instead, and a band whose first row
            // falls past the bottom edge is one the overlay counts as visible while the
            // text view does not draw it.
            $0.fileIndex > current && $0.firstRowBottom <= viewportHeight
        }
        // Every failure below carries the geometry with it. Where in the document this
        // viewport lands is up to TextKit's estimates, so a report from an OS nobody
        // here has measured is only diagnosable if it says what the numbers were.
        let report = """
            viewport \(viewportHeight) pt, current file \(current), \
            bands \(bands.map { "\($0.fileIndex)@\($0.y)" }), \
            bars \(bars.map { "\($0.fileIndex)@\($0.y)" })
            """

        XCTAssertFalse(bands.isEmpty,
                       "the fixture must draw a band for the bars to miss — \(report)")
        XCTAssertEqual(bars.map(\.fileIndex), Array(current..<(current + bars.count)),
                       "the pinned file's bar, then one per following band, none missing — \(report)")
        // The exact push arithmetic is pinned by the three tests above, which drive it
        // deliberately; here a band may or may not overlap the pinned bar, so what has
        // to hold is only that the bar rests at the top edge or is displaced by at most
        // the overlap.
        let pinned = try XCTUnwrap(bars.first, report)
        XCTAssertLessThanOrEqual(pinned.y, 0, "the pinned bar cannot hang below the top edge — \(report)")
        XCTAssertGreaterThanOrEqual(pinned.y, -DiffTextAssembly.headerBandHeight,
                                    "a band pushes the pinned bar out by the overlap, no further — \(report)")

        for band in bands {
            let bar = try XCTUnwrap(
                bars.first { $0.fileIndex == band.fileIndex },
                "file \(band.fileIndex)'s band is drawn at \(band.y) and carries no bar — \(report)")
            XCTAssertEqual(bar.y, band.y, accuracy: 1,
                           "file \(band.fileIndex)'s bar sits at \(bar.y), "
                               + "its band is drawn at \(band.y) — \(report)")
        }
    }

    /// A burst of layout passes must cost exactly one re-resolution.
    ///
    /// The settled-layout trigger fires per layout pass, and a refresh produces
    /// several — the storage swap, then every carried and progressive highlight
    /// painted into it — while Casper recomputes the diff on every file change. Only
    /// the last pass of a burst carries the settled geometry, and resolving costs a
    /// `fileIndex(atY:)` point probe that is O(scroll offset), so the requests are
    /// mutualised into one instead of paid per pass.
    ///
    /// Five real layout passes rather than five calls to the hook, so what is pinned
    /// is the path the app takes.
    func testABurstOfLayoutPassesResolvesTheBarsOnce() throws {
        let (controller, _) = makeHostedSurface(makeWrappingDocument(fileCount: 3, linesPerFile: 40))
        let coordinator = try XCTUnwrap(controller.coordinator)
        drainPendingBarUpdates()
        let before = coordinator.stickyHeader.resolutionCount

        for _ in 0..<5 {
            coordinator.textView.needsLayout = true
            coordinator.textView.layoutSubtreeIfNeeded()
        }

        XCTAssertEqual(coordinator.stickyHeader.resolutionCount, before,
                       "a layout pass must not resolve the bars synchronously")
        drainPendingBarUpdates()
        XCTAssertEqual(coordinator.stickyHeader.resolutionCount, before + 1,
                       "five layout passes must collapse into one re-resolution")
        // And the queue is not one-shot: the next burst gets its own resolution, so
        // no repaint can be lost to a flag that stayed set.
        coordinator.textView.needsLayout = true
        coordinator.textView.layoutSubtreeIfNeeded()
        drainPendingBarUpdates()
        XCTAssertEqual(coordinator.stickyHeader.resolutionCount, before + 2)
    }

    /// Turns the main run loop until it has nothing left to do, which is where the
    /// surface's coalesced bar update runs — nothing turns that loop in a test.
    ///
    /// **To idle, rather than one pass.** A single pass is not enough, because the work
    /// this waits for can be two turns away: `NSHostingView.rootView` is not guaranteed
    /// to push the document into `updateNSView` synchronously, so one pass can be spent
    /// applying the swap and running the layout pass it provokes — which is what queues
    /// the re-resolution, on the *next* turn, through `CFRunLoopPerformBlock`. Under a
    /// full-suite run that ordering is what actually happens, and a one-pass drain then
    /// reads bars nothing has resolved yet. The app never sees it: its run loop turns
    /// continuously, so a queued block always runs on the following turn.
    ///
    /// Capped, so a repaint that re-queues itself fails a test instead of hanging the
    /// suite — generously, since the cap is not a budget anything asserts on.
    private func drainPendingBarUpdates() {
        for _ in 0..<100 {
            // `.handledSource` means that pass ran something, so another may have been
            // queued behind it; anything else means the loop found no work at all.
            guard CFRunLoopRunInMode(.defaultMode, 0, false) == .handledSource else { return }
        }
        XCTFail("the main run loop still had work after 100 passes")
    }

    /// The view value SwiftUI hosts, for a test that has to hand it a second one:
    /// `NSHostingView.rootView` needs both to be the same type.
    private func hostedSurface(
        _ controller: DiffSurfaceController, revision: Int, document: DiffDocument,
        highlights: [String: DiffFileHighlight] = [:]
    ) -> some View {
        DiffTextSurface(
            controller: controller,
            rendering: DiffRendering(revision: revision, document: document, highlights: highlights))
            .frame(width: 480, height: 600)
    }

    /// Highlights matching `makeWrappingDocument`'s lines, so they are actually
    /// painted: `DiffTextAssembly.applyHighlight` drops any whose length disagrees
    /// with the diff line's.
    private func makeWrappingHighlights(
        for document: DiffDocument, linesPerFile: Int
    ) -> [String: DiffFileHighlight] {
        let lines = (1...linesPerFile).map { lineNumber -> AttributedString in
            var line = AttributedString(
                "line \(lineNumber) " + String(repeating: "wrapping content ", count: 12))
            line.foregroundColor = .purple
            return line
        }
        return Dictionary(
            uniqueKeysWithValues: document.files.map { ($0.id, DiffFileHighlight(new: lines, old: nil)) })
    }

    /// One reserved band the text view draws inside the viewport.
    private struct DrawnBand {
        let fileIndex: Int
        /// The band's top edge, relative to the viewport's own top edge — the very
        /// coordinate a `DiffStickyHeader.Bar` carries.
        let y: CGFloat
        /// The bottom of the file's first row, in the same coordinates. What tells a
        /// band drawn whole from one straddling the viewport's bottom edge.
        let firstRowBottom: CGFloat
    }

    /// Every reserved band the text view draws inside the viewport, top-down, in the
    /// overlay's coordinates.
    ///
    /// Read through a single `fragments(in:)` call over the viewport, which is the call
    /// `DiffTextView.drawBackground(in:)` itself makes, so these are the positions the
    /// row tints and the gutter's stripes are lining up with — the only frame of
    /// reference in which a misplaced bar means anything.
    ///
    /// A file's band abuts its first row: TextKit folds `headerBandHeight +
    /// interFileGap` into the layout fragment ahead of that row, and the band is the
    /// lower `headerBandHeight` of it. So the bands on screen are exactly the drawn
    /// rows that open a file.
    private func drawnBands(
        in coordinator: DiffTextSurface.Coordinator, document: DiffDocument
    ) throws -> [DrawnBand] {
        let geometry = try XCTUnwrap(coordinator.geometry)
        let topEdge = visibleTop(of: coordinator)
        let viewport = CGRect(x: 0, y: topEdge, width: coordinator.clipView.bounds.width,
                              height: coordinator.clipView.bounds.height)
        let fileIndexByFirstLine = Dictionary(
            uniqueKeysWithValues: document.files.indices.map { (document.files[$0].firstLineIndex, $0) })
        return geometry.fragments(in: viewport).compactMap { row in
            guard row.isLineStart, let fileIndex = fileIndexByFirstLine[row.lineIndex] else { return nil }
            return DrawnBand(fileIndex: fileIndex,
                             y: row.rect.minY - DiffTextAssembly.headerBandHeight - topEdge,
                             firstRowBottom: row.rect.maxY - topEdge)
        }
    }

    /// The viewport's top edge in the text container's coordinates, which is what
    /// the geometry answers in.
    private func visibleTop(of coordinator: DiffTextSurface.Coordinator) -> CGFloat {
        coordinator.clipView.bounds.origin.y - coordinator.textView.textContainerOrigin.y
    }

    /// Scrolls the viewport so the file's reserved band sits `distance` below its
    /// top edge — `d` in the push arithmetic. Driving the clip view directly also
    /// exercises the bounds-change observer the overlay hangs off.
    private func scroll(
        _ coordinator: DiffTextSurface.Coordinator, soThatFileAt fileIndex: Int,
        sitsBelowTheTopEdgeBy distance: CGFloat
    ) throws {
        let geometry = try XCTUnwrap(coordinator.geometry)
        geometry.ensureLayout(throughFileAt: fileIndex)
        let bandTop = try XCTUnwrap(geometry.top(ofFileAt: fileIndex))
        let clipView = coordinator.clipView
        let target = bandTop + coordinator.textView.textContainerOrigin.y - distance
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: target))
        coordinator.scrollView.reflectScrolledClipView(clipView)
    }

    /// What the overlay actually painted, read back row by row.
    ///
    /// `cacheDisplay(in:to:)` renders a view through its real `draw(_:)` path into
    /// an offscreen bitmap, with no window, no screen and no screen-recording
    /// permission involved — the technique `DiffChromeTests.ChromeProbe` documents
    /// at length. The overlay paints opaque bars and leaves the rest of itself
    /// untouched so the text scrolls through, so alpha is what tells a bar from
    /// the gap below it.
    ///
    /// `@MainActor` explicitly: a nested type does not inherit the enclosing one's
    /// isolation, and every AppKit call below needs it.
    @MainActor
    private struct HeaderProbe {
        private let bitmap: NSBitmapImageRep
        private let bounds: NSRect

        init(_ header: DiffStickyHeader) throws {
            bounds = header.bounds
            bitmap = try XCTUnwrap(header.bitmapImageRepForCachingDisplay(in: bounds))
            header.cacheDisplay(in: bounds, to: bitmap)
        }

        /// The overlay's painted vertical spans, in its own points, top-down.
        var paintedBands: [ClosedRange<CGFloat>] {
            var bands: [ClosedRange<CGFloat>] = []
            var start: Int?
            for row in 0..<bitmap.pixelsHigh {
                let isPainted = (color(atRow: row).alphaComponent) > 0.5
                switch (isPainted, start) {
                case (true, nil): start = row
                case (false, let first?):
                    bands.append(points(first)...points(row))
                    start = nil
                default: break
                }
            }
            if let start { bands.append(points(start)...points(bitmap.pixelsHigh)) }
            return bands
        }

        /// What the overlay painted at `y` in its own coordinates, sampled at its
        /// horizontal middle — clear of the title's glyphs on the left and of the
        /// `+N`/`−N` counts on the right.
        func color(atY y: CGFloat) -> NSColor {
            color(atRow: Int(y * scale))
        }

        /// The bitmap comes back at the display's backing scale, so its rows are
        /// pixels and not points (2× on a Retina Mac).
        private var scale: CGFloat { CGFloat(bitmap.pixelsHigh) / bounds.height }

        private func points(_ row: Int) -> CGFloat { CGFloat(row) / scale }

        private func color(atRow row: Int) -> NSColor {
            bitmap.colorAt(x: bitmap.pixelsWide / 2, y: row) ?? .clear
        }
    }
}

/// The largest per-channel difference between two colors, both taken into device
/// RGB — how a color read out of a bitmap gets compared to a catalog color at all.
private func channelDistance(_ one: NSColor, _ other: NSColor) -> CGFloat {
    guard let one = one.usingColorSpace(.deviceRGB), let other = other.usingColorSpace(.deviceRGB) else {
        return .greatestFiniteMagnitude
    }
    return max(abs(one.redComponent - other.redComponent),
               abs(one.greenComponent - other.greenComponent),
               abs(one.blueComponent - other.blueComponent))
}
