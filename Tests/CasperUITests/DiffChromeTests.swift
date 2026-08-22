import AppKit
import CasperGit
import XCTest

@testable import CasperUI

/// What `DiffTextView` and `DiffGutterRuler` actually paint, read back pixel by
/// pixel — plus the gutter's own width, and their tolerance for being drawn before
/// they are fully configured.
///
/// The rewrite these two views belong to has to be *visually equivalent* to the
/// row-based renderer it replaces, so what the chrome looks like is a requirement
/// and not a detail. `ChromeProbe` below makes that assertable without a screen;
/// read its documentation before adding a case here.
@MainActor
final class DiffChromeTests: XCTestCase {
    // MARK: - Fixtures

    /// The text view's frame: 400 pt wide so the fixture's long line wraps, and
    /// tall enough for the whole fixture to be laid out inside the bitmaps the
    /// probe reads — a row past the bottom edge would be read back out of range,
    /// which `makeProbe` asserts against.
    private static let textViewSize = NSSize(width: 400, height: 900)
    private static let scrollViewWidth: CGFloat = 500

    /// A one-line file whose line number sets the width its gutter needs.
    private func file(named name: String, widestLineNumber: Int) -> GitDiffFile {
        let line = GitDiffLine(
            kind: .addition, content: "x", oldLineNumber: nil, newLineNumber: widestLineNumber)
        return file(named: name, lines: [line])
    }

    private func file(named name: String, lines: [GitDiffLine]) -> GitDiffFile {
        let hunk = GitDiffHunk(header: "@@ -1,\(lines.count) +1,\(lines.count) @@", oldStart: 1,
                               oldLines: lines.count, newStart: 1, newLines: lines.count, lines: lines)
        return GitDiffFile(oldPath: name, newPath: name, status: .modified, isBinary: false, hunks: [hunk])
    }

    /// A narrow file *followed* by a five-digit one, so a gutter sized from the
    /// first file — or from the rows currently on screen — comes out too narrow.
    private func makeDocument() -> DiffDocument {
        DiffDocument(diff: GitDiff(files: [
            file(named: "narrow.swift", widestLineNumber: 7),
            file(named: "wide.swift", widestLineNumber: 12_345),
        ]))
    }

    /// Every row kind the chrome distinguishes, in one document, twice over: a hunk
    /// header, a context row, an addition, a deletion, a line long enough to wrap
    /// into several visual rows, and a second file so there is a reserved header
    /// band inside the text flow as well as the one the text view's inset provides
    /// for the first file.
    ///
    /// Two of these lines are load-bearing beyond their kind:
    ///
    /// - The context row ahead of the addition: a test below samples just above the
    ///   addition's top edge and requires that neighbour to be untinted.
    /// - The wrapping addition, which is what makes the "print the number once per
    ///   *line*, not once per row" rule observable at all. It is deliberately not
    ///   the file's last line, so a scan across one of its rows can never spill into
    ///   the reserved band that follows a file.
    private func makeMixedDocument() -> DiffDocument {
        let wrapping = (1...30).map { "word\($0)" }.joined(separator: " ")
        let lines = [
            GitDiffLine(kind: .context, content: "kept", oldLineNumber: 1, newLineNumber: 1),
            GitDiffLine(kind: .addition, content: "added", oldLineNumber: nil, newLineNumber: 2),
            GitDiffLine(kind: .deletion, content: "removed", oldLineNumber: 3, newLineNumber: nil),
            GitDiffLine(kind: .addition, content: wrapping, oldLineNumber: nil, newLineNumber: 4),
            GitDiffLine(kind: .context, content: "tail", oldLineNumber: 4, newLineNumber: 5),
        ]
        return DiffDocument(diff: GitDiff(files: [
            file(named: "a.swift", lines: lines),
            file(named: "b.swift", lines: lines),
        ]))
    }

    /// Scroll view + text view + ruler, wired and configured as `DiffTextSurface`
    /// wires them: the ruler converts coordinates through the view hierarchy, so it
    /// needs one, and both views' arithmetic runs through the text view's container
    /// origin.
    private func makeSurface(document: DiffDocument?) -> (textView: DiffTextView, ruler: DiffGutterRuler) {
        let textView = DiffTextView(frame: NSRect(origin: .zero, size: Self.textViewSize))
        textView.isEditable = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 0, height: DiffTextAssembly.headerBandHeight)

        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: Self.scrollViewWidth, height: Self.textViewSize.height))
        scrollView.documentView = textView
        let ruler = DiffGutterRuler(scrollView: scrollView, textView: textView)
        scrollView.hasVerticalRuler = true
        scrollView.verticalRulerView = ruler
        scrollView.rulersVisible = true
        scrollView.tile()

        if let document {
            textView.textContentStorage?.textStorage?
                .setAttributedString(DiffTextAssembly.makeAttributedText(for: document))
            textView.document = document
            ruler.document = document
        }
        return (textView, ruler)
    }

    // MARK: - Gutter width

    /// The gutter's width places the *code* column, and the number column inside
    /// it, so it is where the rewrite's spacing either matches `DiffLineRow` or
    /// silently drifts from it. A gutter narrower than the document's widest number
    /// also clips a digit, and the number it clips is the one a large file needs
    /// most.
    func testGutterWidthPlacesTheNumberAndCodeColumnsWhereTheRowRendererDid() throws {
        let surface = makeSurface(document: makeDocument())
        // Five digits: `FileSpan.gutterWidth` budgets 5 * 9 + 12. Spelled out rather
        // than read back from `files.map(\.gutterWidth).max()`, which would let the
        // test agree with the implementation by restating it.
        let gutterWidth: CGFloat = 5 * 9 + 12
        // The text view begins where the ruler ends and insets its glyphs by the
        // container's padding, so this sum is where the code's first glyph lands.
        let padding = try XCTUnwrap(surface.textView.textContainer).lineFragmentPadding
        let codeColumn = surface.ruler.ruleThickness + padding

        // `DiffLineRow` laid out a 3 pt stripe, then a `gutterWidth`-wide
        // right-aligned number, then 8 pt, then the code — whose first character
        // was the `+`/`-` cue. The cue now has a column of its own at exactly that
        // offset, so the code starts one cue column further right and every one of
        // a wrapped line's display rows shares its leading edge.
        XCTAssertEqual(
            codeColumn,
            DiffGutterRuler.stripeWidth + gutterWidth + DiffGutterRuler.cueColumnWidth
                + DiffGutterRuler.numberToCodeGap)
        // A whole number of points, or the row tint leaves the trailing pixel of
        // the column half-covered — a seam down the gutter's edge.
        XCTAssertEqual(surface.ruler.ruleThickness, surface.ruler.ruleThickness.rounded())
        XCTAssertGreaterThanOrEqual(
            surface.ruler.ruleThickness, DiffGutterRuler.stripeWidth + gutterWidth,
            "the column must still hold the widest number in the document")
    }

    /// The width is a property of the document, so it follows the document being
    /// swapped — including for the empty state, where a column left at its old
    /// width would show as an unexplained indent.
    func testGutterWidthFollowsTheDocumentBeingSwappedOut() throws {
        let surface = makeSurface(document: makeDocument())

        surface.ruler.document = nil

        // Nothing left to number, so the column collapses to its stripe, the cue
        // column and the gap the code column starts after.
        let padding = try XCTUnwrap(surface.textView.textContainer).lineFragmentPadding
        XCTAssertEqual(
            surface.ruler.ruleThickness + padding,
            DiffGutterRuler.stripeWidth + DiffGutterRuler.cueColumnWidth
                + DiffGutterRuler.numberToCodeGap)
    }

    // MARK: - Drawn chrome

    /// Every added and deleted row is tinted its own color across the **whole**
    /// width, well past where the code's glyphs stop — which is what the row-based
    /// renderer's `.background()` covered and what a `.backgroundColor` text
    /// attribute could not. Context rows, hunk headers and notes stay on the plain
    /// background.
    ///
    /// Rendered through the view's real `draw(_:)` path, so this also pins that
    /// `drawBackground(in:)` still gets called there: TextKit 2 renders text through
    /// per-fragment layers, and every tint in the diff rests on that hook being
    /// invoked.
    func testRowTintsCoverTheFullWidthOfChangedRowsOnly() throws {
        let probe = try makeProbe(makeMixedDocument())
        let farEdge = probe.textView.bounds.maxX - 1

        for row in probe.rows {
            let kind = probe.document.lines[row.lineIndex].kind
            XCTAssertLessThan(probe.pastTheGlyphs(of: row), farEdge,
                              "row \(row.lineIndex) leaves nowhere to sample")

            for x in [probe.pastTheGlyphs(of: row), farEdge] {
                assertSameColor(
                    probe.codeColor(x: x, y: probe.middle(of: row)), probe.expectedBackground(of: row),
                    "row \(row.lineIndex) (\(kind)) at x \(x)")
            }
        }
        // The fixture has to exercise every kind, or the loop proves nothing about
        // the ones it never met.
        XCTAssertEqual(Set(probe.rows.map { probe.document.lines[$0.lineIndex].kind }),
                       [.hunkHeader, .context, .addition, .deletion])
    }

    /// The blank band reserved ahead of each file is not a row: no tint, no stripe,
    /// in either view. It is where the sticky header bar draws, and chrome bleeding
    /// into it would show around the bar.
    func testTheReservedHeaderBandCarriesNoChrome() throws {
        let probe = try makeProbe(makeMixedDocument())
        // The first file's band is the text view's inset, which sits above the text
        // container's origin; every later file reserves its own inside the text flow,
        // where the geometry can point at it.
        var bandMiddles = [DiffTextAssembly.headerBandHeight / 2]
        for fileIndex in 1..<probe.document.files.count {
            let bandTop = try XCTUnwrap(probe.geometry.top(ofFileAt: fileIndex))
            bandMiddles.append(probe.viewY(ofContainerY: bandTop) + DiffTextAssembly.headerBandHeight / 2)
        }

        for y in bandMiddles {
            assertSameColor(probe.codeColor(x: probe.textView.bounds.midX, y: y),
                            probe.textView.backgroundColor, "text view at y \(y)")
            assertSameColor(probe.gutterColor(x: DiffGutterRuler.stripeWidth / 2, y: y),
                            probe.textView.backgroundColor, "gutter at y \(y)")
        }
    }

    /// The two views place a row from the same geometry but in different coordinate
    /// spaces — the ruler's own, and the text view's, which holds the first file's
    /// reserved band above its text container. Sampling both at one *text-view* `y`
    /// pins the conversion **on the way out**, where the chrome is filled: get that
    /// wrong in either view and the stripe separates from the row it belongs to by a
    /// whole band height.
    ///
    /// It says nothing about the conversion on the way *in*, where the dirty rect
    /// becomes a geometry query — over a dirty rect that covers the whole view, the
    /// queried row set is the same either way.
    /// `testARowStraddlingARepaintedStripIsDrawnWhole` is what pins that direction.
    func testTheGutterChromeLinesUpWithTheRowItBelongsTo() throws {
        let probe = try makeProbe(makeMixedDocument())
        let index = try XCTUnwrap(probe.rows.firstIndex { probe.kind(of: $0) == .addition })
        let row = probe.rows[index]
        XCTAssertEqual(probe.kind(of: probe.rows[index - 1]), .context, "the row above must be untinted")

        for y in [probe.top(of: row) + 0.5, probe.bottom(of: row) - 0.5] {
            assertSameColor(probe.codeColor(x: probe.textView.bounds.midX, y: y),
                            NSColor(DiffLineStyle.background(for: .addition)), "text view at y \(y)")
            assertSameColor(probe.gutterColor(x: DiffGutterRuler.stripeWidth / 2, y: y),
                            NSColor(DiffLineStyle.accent(for: .addition)), "gutter at y \(y)")
        }

        // A point above the row belongs to the context row ahead of it: neither view
        // may spill into it.
        let above = probe.top(of: row) - 1
        assertSameColor(probe.codeColor(x: probe.textView.bounds.midX, y: above),
                        probe.textView.backgroundColor, "text view above the row")
        assertSameColor(probe.gutterColor(x: DiffGutterRuler.stripeWidth / 2, y: above),
                        probe.textView.backgroundColor, "gutter above the row")
    }

    /// While scrolling, AppKit repaints only the strip that was just exposed, and
    /// both views turn that strip into a geometry query by converting it into text-
    /// container coordinates. A conversion missing there — while the fill still has
    /// it — asks for the rows of a *different* strip of the document, and the rows
    /// straddling the exposed strip's top edge come back undrawn: about a band's
    /// worth of untinted, unstriped rows at the top of every repainted strip, on
    /// every frame, healing only on a full redraw.
    ///
    /// So the strip has to start below the first row for this to say anything —
    /// which is exactly why the full-bounds cases above cannot say it.
    func testARowStraddlingARepaintedStripIsDrawnWhole() throws {
        let document = makeMixedDocument()
        let full = try makeProbe(document)
        // The deepest changed row, so the strip starts far enough down that a query
        // shifted by a band height cannot reach it by accident.
        let row = try XCTUnwrap(full.rows.last { full.kind(of: $0) == .addition })
        let stripTop = full.middle(of: row).rounded()
        XCTAssertGreaterThan(stripTop, DiffTextAssembly.headerBandHeight * 2,
                             "the strip must start well below the first row")

        let probe = try makeProbe(document, repaintingFrom: stripTop)

        // The row is filled at its full height and the graphics context clips it, so
        // the strip's very first pixels carry the row's chrome.
        for y in [stripTop + 0.5, probe.bottom(of: row) - 0.5] {
            assertSameColor(probe.codeColor(x: probe.pastTheGlyphs(of: row), y: y),
                            NSColor(DiffLineStyle.background(for: .addition)), "text view at y \(y)")
            assertSameColor(probe.gutterColor(x: DiffGutterRuler.stripeWidth / 2, y: y),
                            NSColor(DiffLineStyle.accent(for: .addition)), "gutter at y \(y)")
        }
    }

    /// The stripe is `stripeWidth` wide and hugs the leading edge, and only a
    /// changed row has one. Sampled either side of its trailing edge rather than
    /// measured, which is the same statement without a pixel count in it.
    func testTheAccentStripeIsStripeWidthWideOnChangedRowsOnly() throws {
        let probe = try makeProbe(makeMixedDocument())
        let insideStripe = DiffGutterRuler.stripeWidth - 0.5
        let pastStripe = DiffGutterRuler.stripeWidth + 0.5

        for kind in [GitDiffLine.Kind.addition, .deletion] {
            let row = try XCTUnwrap(probe.rows.first { probe.kind(of: $0) == kind })
            assertSameColor(probe.gutterColor(x: insideStripe, y: probe.middle(of: row)),
                            NSColor(DiffLineStyle.accent(for: kind)), "\(kind) stripe")
            // Immediately past the stripe the gutter carries the row's tint: that is
            // what makes the tint run unbroken under the gutter, as it did when the
            // number lived inside the tinted row.
            assertSameColor(probe.gutterColor(x: pastStripe, y: probe.middle(of: row)),
                            NSColor(DiffLineStyle.background(for: kind)), "\(kind) tint past the stripe")
        }

        let context = try XCTUnwrap(probe.rows.first { probe.kind(of: $0) == .context })
        assertSameColor(probe.gutterColor(x: insideStripe, y: probe.middle(of: context)),
                        probe.textView.backgroundColor, "context row has no stripe")
    }

    /// The gutter meets the code column with nothing between them. `NSRulerView`
    /// paints its own chrome around whatever `drawHashMarksAndLabels(in:)` draws, and
    /// on some releases that includes a hairline along the edge facing the content —
    /// which the row-based renderer, one view per row, had no way to produce. The
    /// row's tint has to run all the way to the ruler's last point instead.
    func testTheGuttersTrailingEdgeCarriesTheRowTintAndNoDivider() throws {
        let probe = try makeProbe(makeMixedDocument())
        let trailingEdge = probe.ruler.ruleThickness - 0.5

        for kind in [GitDiffLine.Kind.addition, .deletion] {
            let row = try XCTUnwrap(probe.rows.first { probe.kind(of: $0) == kind })
            assertSameColor(probe.gutterColor(x: trailingEdge, y: probe.middle(of: row)),
                            NSColor(DiffLineStyle.background(for: kind)), "\(kind) row's trailing edge")
        }
        let context = try XCTUnwrap(probe.rows.first { probe.kind(of: $0) == .context })
        assertSameColor(probe.gutterColor(x: trailingEdge, y: probe.middle(of: context)),
                        probe.textView.backgroundColor, "context row's trailing edge")
    }

    /// The gutter number takes its row's color: the neutral gray on a context row,
    /// the row's own accent on a changed one — `DiffLineRow.numberColor`'s rule.
    ///
    /// Asserted against the color *composited over the row it was drawn on*, not
    /// against the style constant: `contextNumberTint` is a translucent
    /// `tertiaryLabelColor`, so what reaches the bitmap is that gray blended with
    /// the row's background. Comparing to the blend is what makes this say "*that*
    /// gray" instead of merely "some gray" — `.labelColor`, `.secondaryLabelColor`
    /// or plain white would all pass the weaker statement while looking clearly
    /// different in the gutter.
    func testLineNumbersTakeTheirRowsColor() throws {
        let probe = try makeProbe(makeMixedDocument())
        var numbered = 0

        for row in probe.rows where row.isLineStart && probe.document.lines[row.lineIndex].number != nil {
            let kind = try XCTUnwrap(probe.kind(of: row))
            let tint = kind == .context
                ? NSColor(DiffLineStyle.contextNumberTint) : NSColor(DiffLineStyle.accent(for: kind))
            let expected = composite(tint, over: probe.expectedBackground(of: row))
            let ink = probe.numberInk(in: row)
            numbered += 1

            XCTAssertGreaterThan(ink.deviation, 0.1, "no number drawn for row \(row.lineIndex) (\(kind))")
            // Loose enough to absorb the glyph's antialiasing and the round trip
            // through the bitmap's 8 bits per channel: measured 0.002 on an accent
            // number and 0.052 on the translucent context gray. Far tighter than the
            // colors this has to tell apart — `.secondaryLabelColor` in place of the
            // context tint lands 0.32 away.
            XCTAssertLessThan(
                channelDistance(ink.color, expected), 0.1,
                "row \(row.lineIndex) (\(kind)) drew \(ink.color), expected \(expected)")
        }
        XCTAssertEqual(numbered, 10, "each file's five diff lines print one number each")
    }

    /// The `+`/`-` is drawn in the gutter's cue column, in its row's accent — and
    /// a context row's column stays empty, where the cue used to be a space in the
    /// text.
    ///
    /// This is the whole reason the cue moved: in the gutter it cannot indent the
    /// code, so a wrapped line's display rows share one leading edge, and it
    /// cannot land inside a selection or a copy.
    func testChangedRowsDrawTheirCueInTheGutter() throws {
        let probe = try makeProbe(makeMixedDocument())
        var cued = 0

        for row in probe.rows where row.isLineStart {
            let ink = probe.cueInk(in: row)
            // A context row announces nothing — where the cue used to be a space
            // in its text — and a hunk header or note has no kind at all.
            guard let kind = probe.kind(of: row), kind != .context else {
                XCTAssertLessThan(ink.deviation, 0.02,
                                  "row \(row.lineIndex) must leave its cue column empty")
                continue
            }
            cued += 1
            let expected = composite(NSColor(DiffLineStyle.accent(for: kind)),
                                     over: probe.expectedBackground(of: row))

            XCTAssertGreaterThan(ink.deviation, 0.1, "no cue drawn for row \(row.lineIndex) (\(kind))")
            XCTAssertLessThan(
                channelDistance(ink.color, expected), 0.1,
                "row \(row.lineIndex) (\(kind)) drew \(ink.color), expected \(expected)")
        }
        XCTAssertEqual(cued, 6, "each file's two additions and one deletion carry a cue")
    }

    /// A wrapped line covers several visual rows but is one line, so its number is
    /// printed once, on the row that starts it — a rule the row-based renderer got
    /// for free, one view per line, and this one has to enforce. Its continuation
    /// rows still carry the tint, so a wrapped addition reads as one unbroken band.
    func testAWrappedLinesNumberIsPrintedOnlyOnItsFirstRow() throws {
        let probe = try makeProbe(makeMixedDocument())
        let rowsByLine = Dictionary(grouping: probe.rows, by: \.lineIndex)
        let wrappedLine = try XCTUnwrap(rowsByLine.filter { $0.value.count > 1 }.keys.min(),
                                        "the fixture must contain a line that wraps")
        let rows = probe.rows.filter { $0.lineIndex == wrappedLine }
        let kind = try XCTUnwrap(probe.kind(of: rows[0]))

        XCTAssertTrue(rows[0].isLineStart)
        XCTAssertGreaterThan(probe.numberInk(in: rows[0]).deviation, 0.1,
                             "the row that starts the line prints its number")
        for (offset, row) in rows.dropFirst().enumerated() {
            XCTAssertFalse(row.isLineStart, "only the first row starts the line")
            XCTAssertLessThan(probe.numberInk(in: row).deviation, 0.02,
                              "continuation row \(offset) must print no number")
            assertSameColor(
                probe.gutterColor(x: DiffGutterRuler.stripeWidth + 0.5, y: probe.middle(of: row)),
                NSColor(DiffLineStyle.background(for: kind)),
                "continuation row \(offset) must keep the row tint")
        }
    }

    // MARK: - The composed surface

    /// The gutter drawn *inside its scroll view*, which is the only place its own
    /// clipping is observable — and the case that shipped broken.
    ///
    /// AppKit hands `drawHashMarksAndLabels(in:)` a rect covering the scroll view's
    /// whole content area rather than the ruler's column, and a ruler's drawing is
    /// not clipped to its bounds. So a background fill of that raw rect lands on top
    /// of the code the clip view has already drawn, and the diff renders as bare
    /// line numbers over an empty panel.
    ///
    /// Every other pixel case here captures the two views **one at a time**, each
    /// through a rect taken from its own bounds, so an escaping fill cannot reach the
    /// text view's bitmap and none of them can see this. Which is exactly why this
    /// one composes the scroll view instead: what a reader sees is the composition,
    /// not either view alone.
    func testTheGutterPaintsNothingOverTheCodeColumn() throws {
        let document = makeMixedDocument()
        let surface = makeSurface(document: document)
        let scrollView = try XCTUnwrap(surface.textView.enclosingScrollView)
        let layoutManager = try XCTUnwrap(surface.textView.textLayoutManager)
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        let geometry = DiffFragmentGeometry(layoutManager: layoutManager, document: document)

        let canvas = try canvas(of: scrollView, repaintingFrom: 0)

        let rows = geometry.fragments(
            in: CGRect(x: 0, y: 0, width: surface.textView.bounds.width, height: 10_000))
        let addition = try XCTUnwrap(
            rows.first { document.lines[$0.lineIndex].diffKind == .addition },
            "the fixture must hold an addition to look for a tint on")
        // Text-view coordinates → the scroll view's: the text view sits right of the
        // gutter, both are unscrolled, and the reserved header band is the text view's
        // own inset above its container.
        let codeX = surface.ruler.ruleThickness + addition.rect.maxX + 1
        let rowY = addition.rect.midY + surface.textView.textContainerInset.height

        // Past the row's last glyph, where only the tint can be — and where a fill
        // that covered the code column would leave the plain background.
        assertSameColor(
            ChromeProbe.color(in: canvas, x: codeX, y: rowY),
            NSColor(DiffLineStyle.background(for: .addition)),
            "the added row's tint, \(codeX - surface.ruler.ruleThickness) pt into the code column")

        // And the code itself is on screen: somewhere across the row's glyph span a
        // pixel differs from the tint it sits on. The tint assertion above would still
        // hold with every glyph painted over, which is the symptom a reader reports.
        let tint = NSColor(DiffLineStyle.background(for: .addition))
        let inked = stride(from: surface.ruler.ruleThickness, to: codeX, by: 0.5).contains { x in
            stride(from: rowY - addition.rect.height / 2, to: rowY + addition.rect.height / 2, by: 0.5)
                .contains { y in channelDistance(ChromeProbe.color(in: canvas, x: x, y: y), tint) > 0.02 }
        }
        XCTAssertTrue(inked, "the added row's glyphs are painted in the code column")
    }

    /// The gutter scrolled, with chrome above the panel it lives in — the second
    /// direction the unclipped ruler paint escaped in.
    ///
    /// AppKit asks for a rect starting a header band's height *above* the ruler's
    /// top edge, so the rows in that band — already scrolled out of the viewport —
    /// have their tint, stripe and number placed above the gutter. Unclipped, they
    /// land on whatever the panel puts over the surface, which in `InspectorPanel`
    /// is the separator continuing the workspace title bar's line.
    func testTheGutterPaintsNothingAboveItsOwnColumn() throws {
        let document = makeMixedDocument()
        let surface = makeSurface(document: document)
        let scrollView = try XCTUnwrap(surface.textView.enclosingScrollView)
        let layoutManager = try XCTUnwrap(surface.textView.textLayoutManager)
        layoutManager.ensureLayout(for: layoutManager.documentRange)

        // A viewport shorter than the document, under a strip standing in for the
        // panel's chrome.
        let strip: CGFloat = 40
        let chrome = StripView(frame: NSRect(x: 0, y: 0, width: Self.scrollViewWidth, height: strip + 300))
        // Captured before the surface is in it, as the reference for what the strip
        // looks like untouched. Read back from a bitmap rather than compared to the
        // color the strip fills with: `NSBitmapImageRep` hands colors back in its own
        // space, and a literal put through that conversion no longer matches itself.
        let untouched = try canvas(of: chrome, repaintingFrom: 0)

        chrome.addSubview(scrollView)
        scrollView.frame = NSRect(x: 0, y: strip, width: Self.scrollViewWidth, height: 300)
        scrollView.tile()
        // Scrolled far enough that several rows sit above the viewport's top edge.
        let clipView = scrollView.contentView
        clipView.scroll(to: CGPoint(x: clipView.bounds.origin.x, y: 120))
        scrollView.reflectScrolledClipView(clipView)

        let painted = try canvas(of: chrome, repaintingFrom: 0)

        for x in stride(from: 0, to: Self.scrollViewWidth, by: 1) {
            for y in stride(from: 0, to: strip, by: 1) {
                assertSameColor(
                    ChromeProbe.color(in: painted, x: x, y: y),
                    ChromeProbe.color(in: untouched, x: x, y: y),
                    "the strip above the surface, at (\(x), \(y))")
            }
        }
    }

    /// A flipped, uniformly filled stand-in for the chrome a panel puts above the
    /// diff surface. Flipped so `y = 0` is its top edge, as `InspectorPanel`'s
    /// stack and `DiffSurfaceContainerView` both are.
    private final class StripView: NSView {
        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            NSColor(deviceRed: 1, green: 0, blue: 1, alpha: 1).setFill()
            dirtyRect.fill()
        }
    }

    // MARK: - Partially configured views

    /// Both views are asked to draw as soon as they are in a window, which is before
    /// the first diff has been computed — and a diff with no files keeps them
    /// documentless for as long as it stays empty. Neither may crash there.
    func testDrawingWithoutADocumentDrawsNoChrome() {
        let surface = makeSurface(document: nil)

        drawingOffscreen {
            surface.textView.drawBackground(in: surface.textView.bounds)
            surface.ruler.drawHashMarksAndLabels(in: surface.ruler.bounds)
        }
    }

    /// A single read of `NSTextView.layoutManager` anywhere migrates the view to the
    /// TextKit 1 stack and nils out `textLayoutManager`, leaving both views with no
    /// geometry to place chrome by. `DiffTextSurface` builds an explicit TextKit 2
    /// chain, but the migration is silent, and a crash would be a poor way to
    /// discover it.
    func testDrawingWithoutTextKitTwoGeometryDrawsNoChrome() {
        let document = makeMixedDocument()
        let storage = NSTextStorage(string: document.text)
        // The TextKit *1* chain, on purpose, and assembled by hand: it is the only
        // way to reach this state without reading `layoutManager` off a text view.
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)

        let textView = DiffTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        scrollView.documentView = textView
        let ruler = DiffGutterRuler(scrollView: scrollView, textView: textView)
        textView.document = document
        ruler.document = document

        XCTAssertNil(textView.textLayoutManager, "the fixture must really be TextKit 1 backed")
        drawingOffscreen {
            textView.drawBackground(in: textView.bounds)
            ruler.drawHashMarksAndLabels(in: ruler.bounds)
        }
    }

    /// Drawing needs a current graphics context, which a bitmap provides without a
    /// window. Nothing reads these pixels back — the point is only that the two draw
    /// methods survive the call.
    private func drawingOffscreen(_ body: () -> Void) {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(Self.scrollViewWidth),
            pixelsHigh: Int(Self.textViewSize.height), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)
        guard let bitmap, let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            XCTFail("could not make an offscreen drawing context")
            return
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        body()
    }

    // MARK: - The pixel probe

    /// Draws the two chrome views through their real `draw(_:)` path and hands back
    /// what they painted.
    ///
    /// `repaintingFrom` is the top of the rect each view is asked to redraw, in its
    /// own coordinates but shared vertically (the two spaces coincide unscrolled).
    /// Left at zero it is the whole view, which is the state after a document swap;
    /// a value below the first row is the state during a scroll, where AppKit
    /// repaints only the strip it just exposed. Both are worth probing: a
    /// container↔view conversion applied to the fill alone, or to the query alone,
    /// draws identically over a full-bounds rect and differently over a strip.
    private func makeProbe(_ document: DiffDocument, repaintingFrom top: CGFloat = 0) throws -> ChromeProbe {
        let surface = makeSurface(document: document)
        let textView = surface.textView
        let ruler = surface.ruler

        let layoutManager = try XCTUnwrap(textView.textLayoutManager)
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        let geometry = DiffFragmentGeometry(layoutManager: layoutManager, document: document)

        // Both views convert by `textContainerOrigin`, which folds the inset together
        // with any centering AppKit applies. The surface applies none, so the probe
        // can use the simpler inset below — but only as long as that holds.
        XCTAssertEqual(textView.textContainerOrigin.y, textView.textContainerInset.height,
                       "the probe assumes an uncentered text container")
        XCTAssertEqual(textView.textContainerInset.height, DiffTextAssembly.headerBandHeight,
                       "the reserved band is the text view's inset")
        // A row the geometry reports but the bitmap does not cover would be read back
        // out of range, so the fixture has to fit inside the view.
        let lastRow = geometry.fragments(
            in: CGRect(x: 0, y: 0, width: textView.bounds.width, height: 100_000)).last
        let documentBottom = (lastRow?.rect.maxY ?? 0) + textView.textContainerInset.height
        XCTAssertLessThanOrEqual(documentBottom, textView.bounds.maxY, "the fixture must fit the probe's view")
        XCTAssertEqual(ruler.bounds.origin.y, 0, "the probe assumes an unscrolled ruler")

        return ChromeProbe(
            document: document, geometry: geometry, textView: textView, ruler: ruler,
            code: try canvas(of: textView, repaintingFrom: top),
            gutter: try canvas(of: ruler, repaintingFrom: top))
    }

    private func canvas(of view: NSView, repaintingFrom top: CGFloat) throws -> ChromeProbe.Canvas {
        let rect = NSRect(x: view.bounds.minX, y: top,
                          width: view.bounds.width, height: view.bounds.maxY - top).integral
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: rect))
        view.cacheDisplay(in: rect, to: bitmap)
        return ChromeProbe.Canvas(bitmap: bitmap, rect: rect)
    }

    /// Reads back what the two chrome views actually painted.
    ///
    /// `cacheDisplay(in:to:)` renders a view through its real `draw(_:)` path into
    /// an offscreen bitmap. **No window, no screen and no screen-recording
    /// permission are involved**, which is what makes pixel assertions possible here
    /// at all — a reader who assumes otherwise will leave visual equivalence, the
    /// one hard requirement of this rewrite, entirely unasserted.
    ///
    /// Three things to respect when extending this:
    ///
    /// - **The bitmap comes back at the display's backing scale, so its pixel
    ///   coordinates are not points** (2× on a Retina Mac). Every accessor below
    ///   takes points and converts with a scale measured off the rep, so the same
    ///   assertions hold at 1×.
    /// - **Row positions come from `DiffFragmentGeometry`, never from literals.** A
    ///   font-metric change across a macOS release moves every row in the document;
    ///   a hardcoded `y` would then fail for a reason that has nothing to do with the
    ///   chrome.
    /// - **A canvas may cover only part of its view**, when the probe was asked to
    ///   repaint a strip. Sampling outside it fails rather than silently reading the
    ///   nearest edge pixel, which would pass for the wrong reason.
    ///
    /// `@MainActor` because `DiffFragmentGeometry` is: live TextKit layout is
    /// main-thread-only.
    @MainActor
    private struct ChromeProbe {
        /// One view's pixels, plus the rect of that view they cover.
        struct Canvas {
            let bitmap: NSBitmapImageRep
            let rect: NSRect
        }

        let document: DiffDocument
        let geometry: DiffFragmentGeometry
        let textView: DiffTextView
        let ruler: DiffGutterRuler
        private let code: Canvas
        private let gutter: Canvas

        init(
            document: DiffDocument, geometry: DiffFragmentGeometry, textView: DiffTextView,
            ruler: DiffGutterRuler, code: Canvas, gutter: Canvas
        ) {
            self.document = document
            self.geometry = geometry
            self.textView = textView
            self.ruler = ruler
            self.code = code
            self.gutter = gutter
        }

        /// Every laid-out row of the document, in document order.
        var rows: [DiffFragmentGeometry.Fragment] {
            geometry.fragments(in: CGRect(x: 0, y: 0, width: textView.bounds.width, height: 10_000))
        }

        func kind(of row: DiffFragmentGeometry.Fragment) -> GitDiffLine.Kind? {
            document.lines[row.lineIndex].diffKind
        }

        /// The row's background as the design calls for it: the tint for a changed
        /// row, the plain text background for everything else. The rule lives here,
        /// in the test, so the tint assertions and the ink measurement below cannot
        /// disagree about what a row sits on.
        func expectedBackground(of row: DiffFragmentGeometry.Fragment) -> NSColor {
            switch document.lines[row.lineIndex].kind {
            case .addition: NSColor(DiffLineStyle.background(for: .addition))
            case .deletion: NSColor(DiffLineStyle.background(for: .deletion))
            case .context, .hunkHeader, .note: textView.backgroundColor
            }
        }

        /// Container `y` → text-view `y`: the inset the text view holds above its
        /// container, which is the first file's reserved header band.
        func viewY(ofContainerY containerY: CGFloat) -> CGFloat {
            containerY + textView.textContainerInset.height
        }

        /// An `x` just past the row's own glyphs, where a full-width tint must still
        /// be painted and the code's ink cannot reach. Where the glyphs stop varies
        /// row by row, which is the very reason the tint spans the view's width
        /// instead of the row's typographic width — so this is where a fill that
        /// followed the glyphs would give itself away.
        ///
        /// No conversion: the surface's `textContainerInset.width` is zero, so
        /// container and view `x` coincide.
        func pastTheGlyphs(of row: DiffFragmentGeometry.Fragment) -> CGFloat { row.rect.maxX + 1 }

        func top(of row: DiffFragmentGeometry.Fragment) -> CGFloat { viewY(ofContainerY: row.rect.minY) }
        func bottom(of row: DiffFragmentGeometry.Fragment) -> CGFloat { viewY(ofContainerY: row.rect.maxY) }
        func middle(of row: DiffFragmentGeometry.Fragment) -> CGFloat { viewY(ofContainerY: row.rect.midY) }

        /// What the text view painted at a point in its own coordinates.
        func codeColor(x: CGFloat, y: CGFloat) -> NSColor {
            Self.color(in: code, x: x, y: y)
        }

        /// What the ruler painted at `x` in its own coordinates and `y` in the *text
        /// view's*. The two vertical spaces coincide unscrolled, and holding the
        /// gutter to the text view's `y` is exactly what the alignment test checks.
        func gutterColor(x: CGFloat, y: CGFloat) -> NSColor {
            Self.color(in: gutter, x: x, y: y)
        }

        /// The pixel of the row's number column that differs most from the row's own
        /// background — the number's ink — and by how much, so a caller can tell a
        /// drawn number from an empty column.
        ///
        /// A scan rather than a single sample: where the digits land depends on the
        /// number's width, the font's metrics and the right-alignment, none of which
        /// a test should have to predict.
        func numberInk(in row: DiffFragmentGeometry.Fragment) -> (color: NSColor, deviation: CGFloat) {
            ink(in: row, from: DiffGutterRuler.stripeWidth, to: cueColumnStart)
        }

        /// The same, over the cue column — the trailing strip of the ruler the
        /// `+`/`-` is drawn in, past where any digit can reach.
        func cueInk(in row: DiffFragmentGeometry.Fragment) -> (color: NSColor, deviation: CGFloat) {
            ink(in: row, from: cueColumnStart, to: ruler.ruleThickness)
        }

        /// Where the number column ends and the cue column begins.
        private var cueColumnStart: CGFloat {
            ruler.ruleThickness - DiffGutterRuler.cueColumnWidth
        }

        private func ink(
            in row: DiffFragmentGeometry.Fragment, from minX: CGFloat, to maxX: CGFloat
        ) -> (color: NSColor, deviation: CGFloat) {
            let background = expectedBackground(of: row)
            var ink = background
            var deviation: CGFloat = 0
            for x in stride(from: minX, to: maxX, by: 0.5) {
                for y in stride(from: top(of: row), to: bottom(of: row), by: 0.5) {
                    let sample = gutterColor(x: x, y: y)
                    let distance = channelDistance(sample, background)
                    guard distance > deviation else { continue }
                    deviation = distance
                    ink = sample
                }
            }
            return (ink, deviation)
        }

        /// Points → pixels, with the scale measured off the rep rather than assumed,
        /// and relative to the rect the canvas covers rather than to the whole view.
        /// `static` so a test can sample a canvas it composed itself, not only the
        /// probe's own two.
        static func color(in canvas: Canvas, x: CGFloat, y: CGFloat) -> NSColor {
            let scale = CGFloat(canvas.bitmap.pixelsWide) / canvas.rect.width
            let pixelX = Int((x - canvas.rect.minX) * scale)
            let pixelY = Int((y - canvas.rect.minY) * scale)
            guard (0..<canvas.bitmap.pixelsWide).contains(pixelX),
                  (0..<canvas.bitmap.pixelsHigh).contains(pixelY)
            else {
                XCTFail("(\(x), \(y)) falls outside the repainted \(canvas.rect)")
                return .clear
            }
            return canvas.bitmap.colorAt(x: pixelX, y: pixelY) ?? .clear
        }
    }
}
