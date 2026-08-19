import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import CasperUI

/// Pins `MarkdownTextView`'s contract: the height it reports, the text view it
/// configures, how a link click is routed, and the character-index-to-link
/// lookup the pointing-hand cursor is built on. Nothing here asserts on the
/// cursor image itself — that is AppKit chrome no headless test can see, and
/// can only be confirmed by hovering a real link in the running app (see the
/// project's `headless-swiftui-layout-tests` memory note).
@MainActor
final class MarkdownTextViewTests: XCTestCase {
    private static let width: CGFloat = 300

    // MARK: - Reported height

    func testHeightGrowsWithMoreContent() {
        let short = MarkdownTextView.height(for: "One short line.", width: Self.width)
        let long = MarkdownTextView.height(
            for: (1...40).map { "Paragraph \($0) of the rendered message." }.joined(separator: "\n\n"),
            width: Self.width)

        XCTAssertGreaterThan(short, 0)
        XCTAssertGreaterThan(long, short)
    }

    func testHeightIsStableForTheSameInput() {
        let markdown = "## Dev server ready\n\n- API: <http://localhost:8080>\n- Docs: <http://localhost:8081>\n"

        let first = MarkdownTextView.height(for: markdown, width: Self.width)
        let second = MarkdownTextView.height(for: markdown, width: Self.width)

        XCTAssertEqual(first, second)
    }

    /// The reported height must come from the very engine the hosted view renders
    /// with. A plain `NSTextView` is TextKit 2 backed, and TextKit 1 answers a
    /// different height for the same string — worst for the `NSTextTable` a GFM
    /// table renders as, so a table is what this measures. The hosted side reads
    /// the layout manager's laid-out extent, never the view's `frame.height`:
    /// that frame is the one `NSHostingView` proposed, so it would only echo the
    /// question back.
    func testReportedHeightMatchesTheHostedViewForATable() throws {
        let markdown = """
            Ports in use:

            | A | B |
            |---|---|
            | 1 | 2 |
            """
        let textView = try hostedTextView(markdown: markdown)
        let layoutManager = try XCTUnwrap(textView.textLayoutManager)
        let documentRange = try XCTUnwrap(layoutManager.textContentManager?.documentRange)
        layoutManager.ensureLayout(for: documentRange)

        let hosted = ceil(layoutManager.usageBoundsForTextContainer.height)
        let reported = MarkdownTextView.height(for: markdown, width: Self.width)

        XCTAssertGreaterThan(hosted, 0)
        // Both sides measure the same content through the same TextKit 2 method
        // (`usageBoundsForTextContainer`), so they land on the same value however
        // `MarkdownAttributedString`'s own spacing constants are tuned — a point of
        // slack covers no more than the `ceil` on either side, and still rejects
        // the TextKit 1 engine gap (a measurably different height for this same
        // table) by a wide margin.
        XCTAssertEqual(reported, hosted, accuracy: 1)
    }

    /// An empty message must report no height at all — the panel adds its own
    /// padding around this view, so any non-zero floor would show as an empty gap.
    func testEmptyMarkdownHasZeroHeight() {
        XCTAssertEqual(MarkdownTextView.height(for: "", width: Self.width), 0)
    }

    // MARK: - Rebuilding on update

    /// `MarkdownAttributedString.make` sizes the thematic break's rasterized rule
    /// to `contentWidth`, so re-hosting the same Markdown at a new width must
    /// still rebuild the text storage — a guard keyed on the Markdown string
    /// alone would skip the rebuild and leave the rule sized to the old width.
    func testChangingWidthRerendersTheSameMarkdown() throws {
        let markdown = "Above\n\n---\n\nBelow"

        func attachmentImageWidth(in textView: NSTextView) throws -> CGFloat {
            let storage = try XCTUnwrap(textView.textStorage)
            let range = (storage.string as NSString).range(of: "\u{FFFC}")
            let attachment = try XCTUnwrap(
                storage.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment)
            return try XCTUnwrap(attachment.image).size.width
        }

        let host = NSHostingView(
            rootView: MarkdownTextView(markdown: markdown, width: Self.width) { _ in true }
                .frame(width: Self.width, height: 400))
        host.frame = CGRect(x: 0, y: 0, width: Self.width, height: 400)
        host.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(Self.firstTextView(in: host))
        XCTAssertEqual(try attachmentImageWidth(in: textView), Self.width, accuracy: 0.5)

        let widerWidth = Self.width + 100
        // Reassigning `rootView` on the same `NSHostingView` is how SwiftUI drives
        // `updateNSView` on the same, already-realized text view — a fresh
        // `NSHostingView` would only exercise `makeNSView` again.
        host.rootView = MarkdownTextView(markdown: markdown, width: widerWidth) { _ in true }
            .frame(width: widerWidth, height: 400)
        host.frame = CGRect(x: 0, y: 0, width: widerWidth, height: 400)
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(try attachmentImageWidth(in: textView), widerWidth, accuracy: 0.5)
    }

    // MARK: - Hosted text view

    func testHostedTextViewIsReadOnlySelectableAndTransparent() throws {
        let textView = try hostedTextView(markdown: "Some **rendered** text.")

        XCTAssertFalse(textView.isEditable)
        XCTAssertTrue(textView.isSelectable)
        XCTAssertFalse(textView.drawsBackground)
    }

    /// The `.link` attribute is what lets `NSTextView` hover and click a link on
    /// its own; without it there is nothing for the native cursor to react to.
    func testHostedTextViewCarriesTheLinkAttribute() throws {
        let textView = try hostedTextView(markdown: "[Casper](https://example.com)")
        let storage = try XCTUnwrap(textView.textStorage)

        var linkedURL: URL?
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let url = value as? URL { linkedURL = url }
        }

        XCTAssertEqual(linkedURL, URL(string: "https://example.com"))
    }

    func testEmptyMarkdownHostsWithoutCrashing() throws {
        let textView = try hostedTextView(markdown: "")

        XCTAssertEqual(textView.string, "")
    }

    // MARK: - Link cursor mapping

    /// `makeNSView` must host a `LinkCursorTextView`, not a plain `NSTextView` —
    /// that subclass is what gives the panel its pointing-hand cursor over links
    /// (see the type's own doc comment). Nothing else in this file asserts the
    /// hosted view's class, so without this, deleting `LinkCursorTextView`
    /// entirely would leave the rest of the suite green.
    func testMakeNSViewHostsALinkCursorTextView() throws {
        let textView = try hostedTextView(markdown: "Some text.")
        XCTAssertTrue(textView is LinkCursorTextView)
    }

    /// Pins the logic the pointing-hand cursor is built on: mapping a point to a
    /// character index via `characterIndexForInsertion(at:)`, then reading the
    /// `.link` attribute at that index. A point over the link text resolves to an
    /// index carrying a `.link`; a point over plain text does not.
    ///
    /// Calls `LinkCursorTextView.linkURL(at:)` itself — the real lookup the
    /// cursor logic runs — rather than re-implementing the same two steps
    /// locally, which would keep passing even if `linkURL(at:)` (or the whole
    /// class) were deleted.
    func testCharacterIndexUnderALinkCarriesTheLinkAttributeAndPlainTextDoesNot() throws {
        let textView = try hostedTextView(markdown: "before [Casper](https://example.com) after")
        let linkCursorView = try XCTUnwrap(textView as? LinkCursorTextView)

        let linkPoint = try centerPoint(ofSubstring: "Casper", in: textView)
        let plainPoint = try centerPoint(ofSubstring: "before", in: textView)

        XCTAssertEqual(linkCursorView.linkURL(at: linkPoint), URL(string: "https://example.com"))
        XCTAssertNil(linkCursorView.linkURL(at: plainPoint))
    }

    // MARK: - Link clicks

    func testHandledLinkClickSuppressesTheSystemOpen() {
        var opened: URL?
        let coordinator = MarkdownTextView.Coordinator { url in
            opened = url
            return true
        }
        let url = try? XCTUnwrap(URL(string: "http://localhost:8080"))

        let handled = coordinator.textView(NSTextView(), clickedOnLink: url as Any, at: 0)

        XCTAssertTrue(handled)
        XCTAssertEqual(opened, url)
    }

    /// Returning `false` is how the panel says "not mine" — `NSTextView` then
    /// falls back to its own system open, so the link still works.
    func testDeclinedLinkClickFallsBackToTheSystem() {
        var opened: URL?
        let coordinator = MarkdownTextView.Coordinator { url in
            opened = url
            return false
        }
        let url = try? XCTUnwrap(URL(string: "mailto:someone@example.com"))

        let handled = coordinator.textView(NSTextView(), clickedOnLink: url as Any, at: 0)

        XCTAssertFalse(handled)
        XCTAssertEqual(opened, url)
    }

    /// A `.link` attribute may legitimately hold a plain string; such a click is
    /// left entirely to `NSTextView` rather than guessed at.
    func testNonURLLinkIsLeftToTheSystem() {
        var invoked = false
        let coordinator = MarkdownTextView.Coordinator { _ in
            invoked = true
            return true
        }

        let handled = coordinator.textView(NSTextView(), clickedOnLink: "not a url", at: 0)

        XCTAssertFalse(handled)
        XCTAssertFalse(invoked)
    }

    // MARK: - Helpers

    /// Realizes the representable the way SwiftUI does, so the assertions run
    /// against the very text view `makeNSView`/`updateNSView` produced.
    private func hostedTextView(markdown: String) throws -> NSTextView {
        let host = NSHostingView(
            rootView: MarkdownTextView(markdown: markdown, width: Self.width) { _ in true }
                .frame(width: Self.width, height: 400))
        host.frame = CGRect(x: 0, y: 0, width: Self.width, height: 400)
        host.layoutSubtreeIfNeeded()
        return try XCTUnwrap(Self.firstTextView(in: host))
    }

    private static func firstTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for subview in view.subviews {
            if let found = firstTextView(in: subview) { return found }
        }
        return nil
    }

    /// The center of the first occurrence of `substring`, in `textView`'s own
    /// coordinate system — matching what `characterIndexForInsertion(at:)` and a
    /// real mouse event both expect.
    ///
    /// Reading `.layoutManager` migrates *this* `textView` to the TextKit 1
    /// compatibility stack (see the `textkit2-layout-geometry` project memory
    /// note); harmless here because this helper never compares against
    /// `height(for:width:)`, which is the one place that migration must not
    /// happen. `textContainerInset = .zero` and `lineFragmentPadding = 0` (set in
    /// `makeNSView`) keep the layout manager's coordinates identical to the
    /// view's own.
    private func centerPoint(ofSubstring substring: String, in textView: NSTextView) throws -> NSPoint {
        let range = (textView.string as NSString).range(of: substring)
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        return NSPoint(x: rect.midX, y: rect.midY)
    }
}
