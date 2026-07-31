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
