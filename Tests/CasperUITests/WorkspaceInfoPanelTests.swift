import AppKit
import SwiftUI
import XCTest
import CasperCore
@testable import CasperUI

/// Layout smoke tests: the panel is a pure function of its Markdown, so what is
/// worth locking in is that it composes and stays inside its declared width
/// whatever the message throws at it. Pixels still need human eyes.
@MainActor
final class WorkspaceInfoPanelTests: XCTestCase {
    /// `NSHostingView.fittingSize` reflects the SwiftUI layout tree as of the
    /// last layout pass, so `layoutSubtreeIfNeeded()` before reading it is
    /// required — not optional the way it looked in the sibling
    /// `WorkspaceCloseProgressViewTests` convention. Without it, `fittingSize`
    /// would answer against a stale or unlaid-out tree, and the hug/cap
    /// assertions below would pass whether or not the panel's sizing actually
    /// works.
    private func layoutSize(for markdown: String) -> CGSize {
        let (model, workspace) = makeSeededModel()
        let view = WorkspaceInfoPanel(model: model, workspace: workspace, markdown: markdown)
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    /// A no-op hug/cap (contentHeight stuck at 0, `ScrollView` always at its
    /// 20 pt floor) would still clear a bare `> 0` check, so the meaningful
    /// assertion is that short content settles well short of the cap — a
    /// mechanism that instead always claimed the full `maxHeight` would land
    /// far above this line.
    func testLaysOutAtDeclaredWidthWithNonZeroHeight() {
        let size = layoutSize(for: "## Dev server ready\n\n- API: <http://localhost:8080>\n")

        XCTAssertEqual(size.width, WorkspaceInfoPanel.width, accuracy: 0.5)
        XCTAssertGreaterThan(size.height, 0)
        XCTAssertLessThan(size.height, WorkspaceInfoPanel.maxHeight - 150)
    }

    /// The discriminating half of the hug/cap contract: 200 lines of content
    /// measure far past `maxHeight`, so the `ScrollView` must clamp to (not
    /// merely stay under) the cap. A broken mechanism that never grows past
    /// its 20 pt floor would fail the lower bound here even though it also
    /// trivially satisfies "stays under the cap".
    func testLongMessageNeitherWidensNorExceedsTheHeightCap() {
        let long = (1...200).map { "- endpoint \($0): <http://localhost:80\($0)>" }.joined(separator: "\n")
        let size = layoutSize(for: long)

        XCTAssertEqual(size.width, WorkspaceInfoPanel.width, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(size.height, WorkspaceInfoPanel.maxHeight)
        // The panel's own 12 pt top/bottom padding sits on top of the capped
        // ScrollView, so the total legitimately exceeds maxHeight; the slack here
        // is that padding (plus a little rounding/scrollbar room), not a loosened cap.
        XCTAssertLessThanOrEqual(size.height, WorkspaceInfoPanel.maxHeight + 40)
    }

    /// NOT a test of the last-resort plain-text fallback in
    /// `MarkdownAttributedString.make` — `.returnPartiallyParsedIfPossible`
    /// already parses an unterminated fence successfully (confirmed directly
    /// against `AttributedString(markdown:options:)`, along with several other
    /// malformed-input probes: a stray backtick, mismatched emphasis, a null
    /// byte, and deeply nested block quotes — none of them threw), so that
    /// fallback path has no known trigger through this app's parsing options.
    /// This only pins that a syntax error a real Foundation parse absorbs still
    /// lays out sanely.
    func testUnterminatedFenceStillParsesAndLaysOut() {
        let size = layoutSize(for: "```\nunterminated fence\n")

        XCTAssertEqual(size.width, WorkspaceInfoPanel.width, accuracy: 0.5)
        XCTAssertGreaterThan(size.height, 0)
        XCTAssertLessThan(size.height, WorkspaceInfoPanel.maxHeight)
    }

    /// The shortest possible content (empty) must floor at `minHeight`, not
    /// collapse to the popover's outer padding alone — the discriminating case
    /// for the floor half of the hug/cap contract, the way
    /// `testLongMessageNeitherWidensNorExceedsTheHeightCap` is for the cap half.
    func testEmptyMessageFloorsAtMinHeight() {
        let size = layoutSize(for: "")

        XCTAssertEqual(size.width, WorkspaceInfoPanel.width, accuracy: 0.5)
        // The panel's own 12pt top/bottom padding (`WorkspaceInfoPanel.padding`,
        // not visible to this test target) sits outside the floored ScrollView.
        XCTAssertEqual(size.height, WorkspaceInfoPanel.minHeight + 24, accuracy: 0.5)
    }

    /// Pins that `MarkdownTextView` wraps at the panel's own CONTENT width — the
    /// declared `width` minus the panel's inner padding on both sides — not at
    /// `width` itself. That distinction is invisible to
    /// `testLaysOutAtDeclaredWidthWithNonZeroHeight` above: the outer
    /// `.frame(width:)` on the `ScrollView` always reports the panel's declared
    /// width regardless of what width the inner text view actually wrapped at,
    /// so feeding the full width to `MarkdownTextView` would only overflow
    /// silently into the padding rather than fail that test.
    func testContentWrapsAtThePanelWidthMinusItsOwnPadding() {
        let correctContentWidth = WorkspaceInfoPanel.width - 24
        let fullWidth = WorkspaceInfoPanel.width

        // Search for the shortest "word word word …" line whose wrap actually
        // differs between the two widths, rather than hardcoding a word count
        // that could stop discriminating under a different font/rendering
        // environment (a fixed count of 60 did not, in practice: both widths
        // wrapped it to the same number of lines).
        var longLine = ""
        var heightAtCorrectWidth: CGFloat = 0
        var heightAtFullWidth: CGFloat = 0
        for wordCount in stride(from: 20, through: 200, by: 4) {
            longLine = Array(repeating: "word", count: wordCount).joined(separator: " ")
            heightAtCorrectWidth = MarkdownTextView.height(for: longLine, width: correctContentWidth)
            heightAtFullWidth = MarkdownTextView.height(for: longLine, width: fullWidth)
            if heightAtCorrectWidth != heightAtFullWidth { break }
        }
        XCTAssertNotEqual(
            heightAtCorrectWidth, heightAtFullWidth,
            "could not find content that wraps differently at the panel's content width vs. its full width")

        let expectedPanelHeight = min(max(heightAtCorrectWidth, WorkspaceInfoPanel.minHeight), WorkspaceInfoPanel.maxHeight) + 24
        let size = layoutSize(for: longLine)

        XCTAssertEqual(size.height, expectedPanelHeight, accuracy: 1)
    }

    /// The hosted text view must keep the *whole* frame the panel measured for
    /// it, so a message too tall for the popover stays readable to its last line
    /// once scrolled. A vertically resizable `NSTextView` sizes itself to the
    /// text it has lazily laid out instead — TextKit 2 lays out viewport-first —
    /// which left the frame hundreds of points shorter than the message and cut
    /// its tail off with no way to scroll to it.
    ///
    /// The window is load-bearing, not decoration: without one, the
    /// `ScrollView`'s document view never lays out, and the text view's frame
    /// says nothing about what a reader would see.
    func testTallMessageKeepsTheFullMeasuredHeightInTheTextView() throws {
        let markdown = Self.tallMarkdown()
        let contentHeight = MarkdownTextView.height(for: markdown, width: WorkspaceInfoPanel.width - 24)
        XCTAssertGreaterThan(
            contentHeight, 2 * WorkspaceInfoPanel.maxHeight,
            "the fixture must be far taller than the panel, or it would never scroll")

        let panel = try hostPanel(markdown, hostHeight: WorkspaceInfoPanel.maxHeight + 24)

        // Equality still holds for THIS fixture, and only because it holds no
        // table: the frame the panel assigns is the larger of this measurement
        // and the height the live view reports having laid out, and a table-free
        // message stays on the very TextKit 2 engine the measurement used, so
        // the two numbers are the same one. A message the live engine lays out
        // taller does get a taller frame — that is
        // `testATableMessageIsSizedByTheEngineThatLaysItOut` below.
        //
        // Only `textLayoutManager` is safe to touch on a hosted view; reading
        // `layoutManager` would migrate it to the TextKit 1 stack (see the
        // `textkit2-layout-geometry` project memory note). The frame alone answers
        // this test anyway.
        XCTAssertEqual(panel.textView.frame.height, contentHeight, accuracy: 1)
    }

    /// Depth-first, so the panel's own text view is found rather than any
    /// scrollbar or chrome `NSTextView` a future `ScrollView` might add above it.
    private static func firstTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for subview in view.subviews {
            if let found = firstTextView(in: subview) { return found }
        }
        return nil
    }

    /// The `ScrollView`'s AppKit backing, found the same depth-first way.
    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }

    // MARK: - Reading the tail of a message that has to scroll

    /// A message far taller than the panel, so the `ScrollView` genuinely
    /// scrolls and its last line is only ever reachable at maximum scroll.
    private static func tallMarkdown() -> String {
        let block = """
            ## Dev server ready

            - API: <http://localhost:8080>
            - Docs: <http://localhost:8081>

            Run `casper info clear` once the run is over.
            """
        return Array(repeating: block, count: 40).joined(separator: "\n\n")
    }

    /// The panel hosted in a real `NSWindow` and laid out.
    ///
    /// The window is load-bearing, not decoration: without one a SwiftUI
    /// `ScrollView`'s document view never lays out, so every geometry read
    /// below would answer against an unresolved view tree and prove nothing.
    @MainActor
    private struct HostedPanel {
        let window: NSWindow
        let host: NSHostingView<WorkspaceInfoPanel>
        let textView: NSTextView
        let scrollView: NSScrollView
        /// The size the panel asked for at its very first layout pass, before
        /// any height the live text view reports has had its main-queue hop to
        /// arrive. An `NSPopover` takes its content size from exactly that
        /// pass, so this is the size a reader ends up looking through.
        let firstPassFittingSize: CGSize

        var clipView: NSClipView { scrollView.contentView }
        var documentHeight: CGFloat { scrollView.documentView?.frame.height ?? 0 }
    }

    private func hostPanel(_ markdown: String, hostHeight: CGFloat) throws -> HostedPanel {
        let (model, workspace) = makeSeededModel()
        let view = WorkspaceInfoPanel(model: model, workspace: workspace, markdown: markdown)
        let host = NSHostingView(rootView: view)
        // Parked far off-screen and never ordered in, the way the production hosts are
        // (`AppModel.makeBackgroundSurfaceNursery`, `BrowserCapture.snapshot`): a window at
        // (0, 0) ordered on-screen flashes in the bottom-left corner of the developer's desktop
        // on every test run, and an ordered window at -100_000 joins Mission Control's layout,
        // whose bounding box then spans ~101,000 px and scales every real window to nothing.
        // Layout only needs a non-nil `window`, which `contentView` gives it either way.
        let window = NSWindow(
            contentRect: NSRect(x: -100_000, y: -100_000, width: WorkspaceInfoPanel.width, height: hostHeight),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        // One pass before the search: SwiftUI realizes the representable's text
        // view during layout, so there is nothing to find until it has run.
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let panel = HostedPanel(
            window: window, host: host,
            textView: try XCTUnwrap(Self.firstTextView(in: host)),
            scrollView: try XCTUnwrap(Self.firstScrollView(in: host)),
            // Read before `settleLayout` below, which is what gives the
            // reported height its hop: this has to be the size the panel asks
            // for knowing nothing but its own measurement.
            firstPassFittingSize: host.fittingSize)
        settleLayout(panel)
        return panel
    }

    /// Drives layout until the height the text view reports back has propagated
    /// through SwiftUI and been laid out again.
    ///
    /// A single `layoutSubtreeIfNeeded()` cannot see it: `LinkCursorTextView`
    /// hands its laid-out height to the panel across a main-queue hop (see that
    /// class's `layout()` for why the write cannot happen inline), so the frame
    /// the panel assigns from it lands a turn later. Each round below is one
    /// layout pass plus one hop, and the loop returns as soon as the frame stops
    /// moving — which also *checks* the settling the reporter's epsilon guard
    /// promises rather than assuming it.
    private func settleLayout(_ panel: HostedPanel, rounds: Int = 8) {
        var previousHeight = CGFloat.nan
        for _ in 0..<rounds {
            // Forced, because the pass that matters is often provoked by
            // something AppKit does not treat as invalidating the text view —
            // migrating the engine underneath it, for one.
            panel.textView.needsLayout = true
            panel.host.layoutSubtreeIfNeeded()
            panel.window.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            if panel.textView.frame.height == previousHeight { return }
            previousHeight = panel.textView.frame.height
        }
        XCTFail("the text view's height never settled: still moving after \(rounds) layout rounds")
    }

    /// The hosted panel scrolled to its maximum offset — the state a reader
    /// reaches by scrolling to the end.
    private func hostScrolledToBottom(_ markdown: String, hostHeight: CGFloat) throws -> HostedPanel {
        let panel = try hostPanel(markdown, hostHeight: hostHeight)
        XCTAssertGreaterThan(
            panel.documentHeight, panel.clipView.bounds.height,
            "the fixture must overflow the viewport, or scrolling to the bottom is a no-op")
        panel.clipView.scroll(
            to: NSPoint(x: 0, y: max(0, panel.documentHeight - panel.clipView.bounds.height)))
        panel.scrollView.reflectScrolledClipView(panel.clipView)
        panel.host.layoutSubtreeIfNeeded()
        panel.window.displayIfNeeded()
        return panel
    }

    /// The scrolled content must end with real slack under its last line. The
    /// panel's own `padding` sits OUTSIDE the `ScrollView`, so it pads the
    /// viewport rather than the document: without an inset inside the scrolled
    /// content the document ends flush with its last line, and at maximum
    /// scroll that line lands exactly on the viewport's bottom edge — where any
    /// sub-point rounding in the real popover clips it and readers report the
    /// tail as truncated.
    func testLastLineKeepsATrailingMarginAtMaximumScroll() throws {
        let panel = try hostScrolledToBottom(
            Self.tallMarkdown(), hostHeight: WorkspaceInfoPanel.maxHeight + 24)

        // TextKit 2 lays out viewport-first, so the tail of the document has no
        // real geometry until layout is forced over the whole range.
        let manager = try XCTUnwrap(panel.textView.textLayoutManager)
        let contentManager = try XCTUnwrap(manager.textContentManager)
        manager.ensureLayout(for: contentManager.documentRange)
        var lastFragment = CGRect.zero
        manager.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
            lastFragment = fragment.layoutFragmentFrame
            return true
        }
        XCTAssertGreaterThan(lastFragment.maxY, 0, "no laid-out fragment to check")

        // Fragment geometry is in text-container coordinates; `textContainerOrigin`
        // folds in the view's inset (see the textkit2-layout-geometry note).
        let origin = panel.textView.textContainerOrigin
        let inClipView = panel.textView.convert(
            lastFragment.offsetBy(dx: origin.x, dy: origin.y), to: panel.clipView)

        XCTAssertLessThanOrEqual(
            inClipView.maxY,
            panel.clipView.bounds.maxY - WorkspaceInfoPanel.contentBottomInset + 0.5,
            "the last line sits within \(WorkspaceInfoPanel.contentBottomInset) pt of the viewport's bottom edge")
    }

    /// The panel must yield to a host shorter than its own natural height
    /// instead of overflowing it. A `ScrollView` pinned to a fixed height hangs
    /// its bottom outside such a host, and the points hanging out are
    /// unreachable at any scroll offset — the message's tail can then never be
    /// read at all.
    func testShortHostStillReachesTheEndOfTheMessage() throws {
        // Well under the panel's natural maxHeight + 2 * padding.
        let hostHeight: CGFloat = 300
        let panel = try hostScrolledToBottom(Self.tallMarkdown(), hostHeight: hostHeight)

        let contentView = try XCTUnwrap(panel.window.contentView)
        let clipInHost = panel.clipView.convert(panel.clipView.bounds, to: contentView)
        let visibleHeight = clipInHost.intersection(contentView.bounds).height
        let maximumOffset = max(0, panel.documentHeight - panel.clipView.bounds.height)

        XCTAssertGreaterThanOrEqual(
            maximumOffset + visibleHeight, panel.documentHeight - 0.5,
            "\(panel.documentHeight - maximumOffset - visibleHeight) pt of the message are unreachable "
                + "in a \(hostHeight) pt host")
    }

    // MARK: - Sizing the text view from the engine that actually lays it out

    /// A message whose GFM tables put an `NSTextTable` in the text storage.
    ///
    /// That is the structure AppKit refuses to keep on TextKit 2: a text view
    /// built explicitly on the TextKit 2 stack still migrates itself to TextKit 1
    /// on a display pass once its storage holds one, and the two engines then
    /// disagree about how tall the same string is.
    ///
    /// The cells are deliberately wide enough to wrap, which is where the
    /// disagreement lives — a table of short cells measures TextKit 1 *shorter*
    /// than TextKit 2, which no frame can be clipped by. Measured at this size:
    /// 1461 pt on TextKit 2 against 1797 pt on TextKit 1, so a frame taken from
    /// the measurement alone loses the last 336 pt.
    private static func tableMarkdown() -> String {
        let block = """
            ## Test run complete

            | Suite | Command | Result |
            | --- | --- | --- |
            | unit | `swift test --filter CasperCoreTests --parallel` | 40/40 passed |
            | integration | `swift test --filter CasperGitTests --parallel` | 15/15 passed |
            | end-to-end | `npm run test:e2e -- --reporter=verbose` | 11/11 passed |
            """
        return Array(repeating: block, count: 6).joined(separator: "\n\n")
    }

    /// The hosted text view must be tall enough for what the engine that is
    /// really laying it out produced — whichever engine that turned out to be.
    ///
    /// A view holding an `NSTextTable` does not stay on TextKit 2, and the
    /// TextKit 1 layout that replaces it is taller for cells that wrap. A frame
    /// sized from a TextKit 2 measurement alone leaves the last lines of such a
    /// message below its bottom edge, clipped by the view's own bounds and so
    /// never drawn, at any scroll offset. The frame therefore comes from
    /// `max(measured, reported)`, and what this pins is that combined frame: the
    /// height the panel assigns covers what the live engine laid out, whichever
    /// of the two numbers supplied it.
    ///
    /// It does not isolate the report half. For this fixture the opening
    /// measurement predicts TextKit 1 and lands on the very height the live view
    /// reports, so `max` is a no-op here and the measurement alone satisfies the
    /// assertion. Isolating the reporter would mean handing the panel a
    /// measurement known to be wrong, which no production API offers;
    /// `MarkdownTextViewTests.testReportedHeightMatchesTheHostedViewForATable`
    /// is what pins the reporter itself.
    ///
    /// The migration is forced here rather than waited for. AppKit usually gets
    /// there first — it migrates the view on its own during the panel's first
    /// display pass — but "usually" is not something a test should rest on, and
    /// reading `NSTextView.layoutManager` performs exactly the same migration
    /// synchronously (see the `textkit2-layout-geometry` project memory note).
    /// Either way the state under test is reached before the assertions run.
    ///
    /// The teeth are in the two engines disagreeing, which was measured on
    /// macOS 26; the assertion itself is a relative one that must hold wherever
    /// the suite runs, including a CI runner whose TextKit may disagree by a
    /// different amount or not at all.
    func testATableMessageIsSizedByTheEngineThatLaysItOut() throws {
        let panel = try hostPanel(Self.tableMarkdown(), hostHeight: WorkspaceInfoPanel.maxHeight + 24)

        let layoutManager = try XCTUnwrap(panel.textView.layoutManager)
        let container = try XCTUnwrap(panel.textView.textContainer)
        XCTAssertNil(
            panel.textView.textLayoutManager,
            "reading `layoutManager` must have migrated the view off TextKit 2, or this test proves nothing")
        settleLayout(panel)

        layoutManager.ensureLayout(for: container)
        let laidOutHeight = layoutManager.usedRect(for: container).height
        XCTAssertGreaterThanOrEqual(
            panel.textView.frame.height, laidOutHeight - 0.5,
            "the last \(laidOutHeight - panel.textView.frame.height) pt of the message fall below the "
                + "text view's frame, where nothing draws them")
    }

    /// The TextKit 2 path must not regress: a table-free message stays on
    /// TextKit 2 for the whole of the panel's life, and the frame it is given
    /// still covers everything that engine laid out. Cheap because it needs no
    /// migration — the point is precisely that none happens.
    func testATableFreeMessageStaysOnTextKit2AndKeepsItsLaidOutHeight() throws {
        let panel = try hostPanel(Self.tallMarkdown(), hostHeight: WorkspaceInfoPanel.maxHeight + 24)

        let layoutManager = try XCTUnwrap(
            panel.textView.textLayoutManager, "a table-free message must still be on the TextKit 2 stack")
        let contentManager = try XCTUnwrap(layoutManager.textContentManager)
        // TextKit 2 lays out viewport-first, so the document's real extent is
        // only known once layout is forced over the whole range.
        layoutManager.ensureLayout(for: contentManager.documentRange)

        XCTAssertGreaterThanOrEqual(
            panel.textView.frame.height, layoutManager.usageBoundsForTextContainer.height - 0.5)
    }

    // MARK: - The height the popover freezes at the first layout pass

    /// A table message short enough to keep the panel hugging its content.
    ///
    /// Modelled on a reported message: a `#` title, a two-column GFM table
    /// whose second column holds a URL long enough to wrap at the panel's
    /// content width, and a heading line after it — the line a reader finds cut
    /// in half by the popover's bottom edge.
    ///
    /// Wrapping cells are the point, as in `tableMarkdown()`: they are where
    /// TextKit 1 lays a table out TALLER than TextKit 2, and only a taller
    /// layout can fall outside a popover already sized from the shorter one. A
    /// table of short cells goes the other way and hides the bug.
    private static func shortTableMarkdown() -> String {
        """
        # Preview deployment is live

        | Environment | URL |
        | --- | --- |
        | Preview | <http://preview.casper.internal:8080/deployments/1f4c9ab/preview?token=demo&trace=on> |
        | Staging | <http://staging.casper.internal:8080/deployments/1f4c9ab/staging?token=demo&trace=on> |

        ## Next steps
        """
    }

    /// The height `content` lays out to at `width` on a throwaway stack of each
    /// TextKit engine, assembled the way `MarkdownTextView` assembles its own.
    ///
    /// Here to pin which regime a fixture is in, never to reproduce the panel's
    /// own answer: the two numbers are only ever compared with each other.
    private static func engineHeights(
        of content: NSAttributedString, width: CGFloat
    ) -> (textKit1: CGFloat, textKit2: CGFloat) {
        let storage = NSTextStorage(attributedString: content)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        layoutManager.ensureLayout(for: container)

        let contentStorage = NSTextContentStorage()
        let textLayoutManager = NSTextLayoutManager()
        let textContainer = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        contentStorage.addTextLayoutManager(textLayoutManager)
        textLayoutManager.textContainer = textContainer
        contentStorage.textStorage?.setAttributedString(content)
        textLayoutManager.ensureLayout(for: contentStorage.documentRange)

        return (
            textKit1: ceil(layoutManager.usedRect(for: container).height),
            textKit2: ceil(textLayoutManager.usageBoundsForTextContainer.height))
    }

    /// The height the live engine has laid the hosted message out to.
    ///
    /// `textLayoutManager` is tested first because merely reading
    /// `layoutManager` is itself what migrates the view off TextKit 2 (see the
    /// `textkit2-layout-geometry` project memory note) — the same order
    /// `LinkCursorTextView.reportLaidOutHeight()` uses, so this reads back the
    /// number the panel was handed rather than manufacturing a second opinion.
    private static func liveLaidOutHeight(of textView: NSTextView) -> CGFloat {
        guard let container = textView.textContainer else { return 0 }
        if let layoutManager = textView.textLayoutManager {
            guard let documentRange = layoutManager.textContentManager?.documentRange else { return 0 }
            // TextKit 2 lays out viewport-first, so the whole extent is only
            // known once layout has been forced over the whole document.
            layoutManager.ensureLayout(for: documentRange)
            return ceil(layoutManager.usageBoundsForTextContainer.height)
        }
        guard let layoutManager = textView.layoutManager else { return 0 }
        layoutManager.ensureLayout(for: container)
        return ceil(layoutManager.usedRect(for: container).height)
    }

    /// The height the panel asks for at its FIRST layout pass must already cover
    /// the height it settles at, because an `NSPopover` takes its content size
    /// from that first pass and never grows it afterwards. Whatever the panel
    /// gains later goes into the scrolled document while the viewport stays
    /// where it was — the message's last line then sits below the popover's
    /// bottom edge, reachable only by scrolling.
    ///
    /// What this discriminates that its neighbours do not:
    ///
    /// - `testATableMessageIsSizedByTheEngineThatLaysItOut` settles the panel
    ///   first and then reads the frame, so a correction that lands a
    ///   main-queue hop late satisfies it. Here the first pass is the deadline.
    /// - `testShortHostStillReachesTheEndOfTheMessage` is about a host with less
    ///   room to offer. The host below is far taller than the panel could ever
    ///   ask for, so the only number under test is the panel's own.
    /// - `testLongMessageNeitherWidensNorExceedsTheHeightCap` covers the capped
    ///   regime. The fixture here stays well under `maxHeight`, which the first
    ///   precondition pins so it cannot drift into the cap and go vacuous.
    ///
    /// Two more preconditions guard the regime the fixture has to be in for the
    /// final assertion to mean anything: TextKit 1 has to be the TALLER engine
    /// for this content — cells that stopped wrapping would flip the sign, and
    /// then the first pass would cover the settled height whether or not the
    /// engine was predicted — and AppKit has to have migrated the hosted view,
    /// since a view still on TextKit 2 never exercises the prediction at all.
    ///
    /// The asked-for height is read as `NSHostingView.fittingSize`, the number
    /// the rest of this file measures the panel by. It is also what decides a
    /// popover's size: `NSPopover` sizes itself from its content view
    /// controller, and an `NSHostingController` answers `sizeThatFits(in:)` from
    /// the very same SwiftUI layout pass.
    func testTheOpeningHeightAlreadyCoversWhatTheLiveEngineLaysOut() throws {
        let markdown = Self.shortTableMarkdown()
        let contentWidth = WorkspaceInfoPanel.width - 24
        let measuredHeight = MarkdownTextView.height(for: markdown, width: contentWidth)
        XCTAssertLessThan(
            measuredHeight, WorkspaceInfoPanel.maxHeight - 100,
            "the fixture must stay in the panel's hug-the-content regime: at \(measuredHeight) pt the cap "
                + "would decide the height and the first pass would already ask for the maximum")

        // Several times what the panel could ask for, so the host constrains nothing.
        let panel = try hostPanel(markdown, hostHeight: 4 * WorkspaceInfoPanel.maxHeight)

        // FIRST touch of this view's engines, before `textStorage` or anything
        // else: merely reading `layoutManager` performs the very migration this
        // asserts AppKit performed by itself (see the `textkit2-layout-geometry`
        // project memory note), so asked any later the question answers itself.
        XCTAssertNil(
            panel.textView.textLayoutManager,
            "AppKit must have migrated the hosted view off TextKit 2 on its own, or the prediction this "
                + "test exists for is never exercised")

        let engines = Self.engineHeights(of: try XCTUnwrap(panel.textView.textStorage), width: contentWidth)
        XCTAssertGreaterThan(
            engines.textKit1, engines.textKit2,
            "this fixture must be one TextKit 1 lays out TALLER, and it lays out at \(engines.textKit1) pt "
                + "against TextKit 2's \(engines.textKit2) pt: only a taller live layout can fall outside a "
                + "popover already sized from the shorter measurement, so with the sign the other way the "
                + "assertion below holds whether or not the engine is predicted")

        panel.host.layoutSubtreeIfNeeded()
        let settledHeight = panel.host.fittingSize.height
        XCTAssertLessThan(
            settledHeight, WorkspaceInfoPanel.maxHeight,
            "the settled panel must still be hugging its content, not sitting on the cap")

        let firstPassHeight = panel.firstPassFittingSize.height
        XCTAssertGreaterThanOrEqual(
            firstPassHeight, settledHeight - 0.5,
            "the popover is sized from the first layout pass, where the panel asks for \(firstPassHeight) pt, "
                + "but the panel settles at \(settledHeight) pt: the last \(settledHeight - firstPassHeight) pt "
                + "of the message fall outside the popover. The opening measurement is \(measuredHeight) pt "
                + "(TextKit 1 lays this content out at \(engines.textKit1) pt, TextKit 2 at "
                + "\(engines.textKit2) pt); the live engine laid it out at "
                + "\(Self.liveLaidOutHeight(of: panel.textView)) pt")
    }

    // MARK: - Link routing

    /// An `http(s)` link must open in the workspace's own browser panel — the
    /// same wiring `ControlHandlerTests.testOpenBrowserLoadsInspectorBrowserAndSelectsTab`
    /// pins for `controlOpenBrowser` itself, exercised here through `openURL`'s
    /// own scheme guard rather than called directly.
    func testOpenURLRoutesHTTPSIntoTheWorkspaceBrowser() throws {
        let (model, workspace) = makeSeededModel()
        let panel = WorkspaceInfoPanel(model: model, workspace: workspace, markdown: "")
        let url = URL(string: "https://example.com")!

        XCTAssertTrue(panel.openURL(url))

        let ws = try XCTUnwrap(model.workspace(id: workspace.id))
        XCTAssertEqual(ws.inspector.tab, .browser)
        guard case .browser(let opened) = ws.inspector.browser.kind else {
            return XCTFail("inspector browser surface is not a browser kind")
        }
        XCTAssertEqual(opened, url)
    }

    /// Holding the system-browser modifier must take the very same http(s) link
    /// out of the app instead. Pinned on the routing decision rather than
    /// through `openURL`, which would really launch the default browser mid-test.
    func testSystemBrowserModifierRoutesHTTPSOutOfTheApp() {
        let url = URL(string: "https://example.com")!

        XCTAssertEqual(
            WorkspaceInfoPanel.destination(for: url, modifiers: WorkspaceInfoPanel.systemBrowserModifier),
            .systemBrowser)
        XCTAssertEqual(WorkspaceInfoPanel.destination(for: url, modifiers: []), .workspaceBrowser)
    }

    /// The modifier only ever switches between two in-app answers for a link the
    /// panel owns; a scheme it does not own is the system's either way, so
    /// holding the modifier must not claim the click.
    func testSystemBrowserModifierLeavesNonHTTPSchemesToTheSystem() throws {
        let (model, workspace) = makeSeededModel()
        let panel = WorkspaceInfoPanel(model: model, workspace: workspace, markdown: "")
        let url = URL(string: "mailto:someone@example.com")!

        XCTAssertEqual(
            WorkspaceInfoPanel.destination(for: url, modifiers: WorkspaceInfoPanel.systemBrowserModifier),
            .system)
        XCTAssertFalse(panel.openURL(url, modifiers: WorkspaceInfoPanel.systemBrowserModifier))

        let ws = try XCTUnwrap(model.workspace(id: workspace.id))
        XCTAssertNotEqual(ws.inspector.tab, .browser)
    }

    /// Every other scheme must fall through to the system instead — pinned
    /// against a real model so deleting the guard (routing everything into the
    /// workspace browser) cannot pass silently: the inspector would stay off
    /// the `.browser` tab it starts on.
    func testOpenURLLeavesNonHTTPSchemesToTheSystem() throws {
        let (model, workspace) = makeSeededModel()
        let panel = WorkspaceInfoPanel(model: model, workspace: workspace, markdown: "")
        let url = URL(string: "file:///etc/hosts")!

        XCTAssertFalse(panel.openURL(url))

        let ws = try XCTUnwrap(model.workspace(id: workspace.id))
        XCTAssertNotEqual(ws.inspector.tab, .browser)
    }
}
