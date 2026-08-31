import AppKit
import XCTest

@testable import CasperUI

/// Pins `MarkdownAttributedString.make` to the attributes and text it must
/// produce for each Markdown element, plus — for block spacing — the layout
/// geometry those attributes actually realize, measured on a real TextKit 2
/// stack (see `layOut`). Only *pixels* are out of reach headlessly; geometry is
/// not, and the project's `headless-swiftui-layout-tests` memory note sanctions
/// exactly this distinction. Colors and chrome still need human eyes.
final class MarkdownAttributedStringTests: XCTestCase {
    private let bodyFont = NSFont.systemFont(ofSize: 13)
    private let textColor = NSColor.labelColor
    // Matches `MarkdownTextViewTests.width`, though nothing here depends on
    // the two staying equal — this is just a plausible panel width to
    // rasterize the thematic break's rule at.
    private let contentWidth: CGFloat = 300

    private func make(_ markdown: String) -> NSAttributedString {
        MarkdownAttributedString.make(markdown, font: bodyFont, textColor: textColor, contentWidth: contentWidth)
    }

    /// Reads the `.font` attribute at the first character of `string`, so
    /// tests can assert on a block's paragraph without hardcoding offsets.
    private func font(in string: NSAttributedString, at index: Int = 0) -> NSFont? {
        guard string.length > index else { return nil }
        return string.attribute(.font, at: index, effectiveRange: nil) as? NSFont
    }

    /// Reads the `.paragraphStyle` attribute at the first character of `string`,
    /// so spacing tests can assert on a block's paragraph without hardcoding
    /// offsets.
    private func paragraphStyle(in string: NSAttributedString, at index: Int = 0) -> NSParagraphStyle? {
        guard string.length > index else { return nil }
        return string.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
    }

    func testEmptyStringYieldsEmptyResult() {
        let result = make("")
        XCTAssertEqual(result.length, 0)
        XCTAssertEqual(result.string, "")
    }

    func testHeadingIsLargerAndBolderThanBody() {
        let result = make("# Heading")
        guard let headingFont = font(in: result) else {
            return XCTFail("heading has no font attribute")
        }
        XCTAssertGreaterThan(headingFont.pointSize, bodyFont.pointSize)
        XCTAssertTrue(NSFontManager.shared.traits(of: headingFont).contains(.boldFontMask))
    }

    func testBoldItalicAndInlineCodeCarryExpectedTraits() {
        let result = make("**bold** *italic* `code`")
        let string = result.string

        let boldRange = (string as NSString).range(of: "bold")
        let italicRange = (string as NSString).range(of: "italic")
        let codeRange = (string as NSString).range(of: "code")

        guard let boldFont = font(in: result, at: boldRange.location),
              let italicFont = font(in: result, at: italicRange.location),
              let codeFont = font(in: result, at: codeRange.location) else {
            return XCTFail("missing font attribute on an inline run")
        }

        XCTAssertTrue(NSFontManager.shared.traits(of: boldFont).contains(.boldFontMask))
        XCTAssertTrue(NSFontManager.shared.traits(of: italicFont).contains(.italicFontMask))
        XCTAssertTrue(codeFont.isFixedPitch)
    }

    func testLinkRangeCarriesItsParsedURL() {
        let result = make("[Casper](https://example.com)")
        let string = result.string
        let linkRange = (string as NSString).range(of: "Casper")

        let url = result.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL
        XCTAssertEqual(url, URL(string: "https://example.com"))
    }

    func testBulletListRendersOneParagraphPerItemWithHangingIndent() {
        let result = make("- Item one\n- Item two")
        let string = result.string

        XCTAssertTrue(string.contains("Item one"))
        XCTAssertTrue(string.contains("Item two"))
        // One paragraph per item: the second item starts on its own line.
        let lines = string.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        // Each item's line carries the bullet marker, not just its text —
        // otherwise a renderer that dropped the marker would still pass.
        XCTAssertTrue(lines[0].hasPrefix("•"))
        XCTAssertTrue(lines[1].hasPrefix("•"))

        let itemStart = (string as NSString).range(of: "Item one").location
        guard let style = result.attribute(.paragraphStyle, at: itemStart, effectiveRange: nil)
            as? NSParagraphStyle else {
            return XCTFail("list item has no paragraph style")
        }
        XCTAssertGreaterThan(style.headIndent, 0)
    }

    func testOrderedListNumbersItemsInOrder() {
        let result = make("1. First\n2. Second\n3. Third")
        let string = result.string

        let firstMarker = string.range(of: "1.")
        let secondMarker = string.range(of: "2.")
        let thirdMarker = string.range(of: "3.")

        XCTAssertNotNil(firstMarker)
        XCTAssertNotNil(secondMarker)
        XCTAssertNotNil(thirdMarker)
        // Markers must appear in the same order as their list items.
        if let first = firstMarker, let second = secondMarker, let third = thirdMarker {
            XCTAssertLessThan(first.lowerBound, second.lowerBound)
            XCTAssertLessThan(second.lowerBound, third.lowerBound)
        }
    }

    /// An unbroken `1.`/`2.`/`3.` list (as in `testOrderedListNumbersItemsInOrder`)
    /// renders identically whether the marker comes from the parsed ordinal or
    /// from a naive running counter, so it cannot tell the two apart. A list
    /// that starts at a non-1 ordinal can only pass if the parsed ordinal —
    /// `PresentationIntent.Kind.listItem(ordinal:)` — is actually used.
    func testOrderedListHonorsNonSequentialStartingOrdinal() {
        let result = make("5. First\n6. Second\n7. Third")
        let string = result.string

        XCTAssertNotNil(string.range(of: "5."))
        XCTAssertNotNil(string.range(of: "6."))
        XCTAssertNotNil(string.range(of: "7."))
        XCTAssertNil(string.range(of: "1."))
    }

    func testTaskListRendersDistinctCheckedAndUncheckedMarkers() {
        let result = make("- [ ] Todo\n- [x] Done")
        let string = result.string

        XCTAssertFalse(string.contains("[ ]"))
        XCTAssertFalse(string.contains("[x]"))
        XCTAssertTrue(string.contains("☐"))
        XCTAssertTrue(string.contains("☑"))
        XCTAssertNotEqual(string.range(of: "☐"), string.range(of: "☑"))
    }

    func testFencedCodeBlockIsMonospacedWithBackground() {
        let result = make("```swift\nlet x = 1\n```")
        let string = result.string
        let codeStart = (string as NSString).range(of: "let x = 1").location

        guard let codeFont = font(in: result, at: codeStart) else {
            return XCTFail("code block has no font attribute")
        }
        XCTAssertTrue(codeFont.isFixedPitch)

        let background = result.attribute(.backgroundColor, at: codeStart, effectiveRange: nil) as? NSColor
        XCTAssertNotNil(background)
    }

    /// `> - item` is both a block quote and a list item; the list branch in
    /// `render(_:tables:)` runs first, so this pins that it still folds in
    /// the quote's indent and leading rule instead of dropping them.
    func testListItemNestedInBlockQuoteComposesQuoteAndListChrome() {
        let plainListResult = make("- Item one")
        guard let plainListStyle = plainListResult.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
            as? NSParagraphStyle else {
            return XCTFail("plain list item has no paragraph style")
        }

        let quotedListResult = make("> - Item one")
        let string = quotedListResult.string
        XCTAssertTrue(string.contains("Item one"))
        XCTAssertTrue(string.contains("•"))

        guard let quotedListStyle = quotedListResult.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
            as? NSParagraphStyle, let rule = quotedListStyle.textBlocks.first else {
            return XCTFail("list item nested in a block quote carries no rule text block")
        }

        XCTAssertGreaterThan(quotedListStyle.headIndent, plainListStyle.headIndent)
        // A border only actually paints once it has both a nonzero width and a
        // set color — a width alone reserves space and draws nothing, which is
        // exactly the bug this pins against (see `blockQuoteRule`'s doc comment).
        XCTAssertGreaterThan(rule.width(for: .border, edge: .minX), 0)
        XCTAssertNotNil(rule.borderColor(for: .minX))
        // Same reasoning as `testBlockQuoteRuleHasAVisibleBorderWidthAndColor`: a
        // bare `NSTextBlock` would satisfy the width/color checks above and still
        // draw nothing.
        XCTAssertTrue(rule is NSTextTableBlock, "block quote rule must be an NSTextTableBlock, not a bare NSTextBlock")
    }

    /// A fenced code block indented under a list item must not sit at the
    /// same fixed indent as a top-level code block.
    func testCodeBlockNestedInListInheritsListIndent() {
        let standaloneResult = make("```\ncode line\n```")
        guard let standaloneStyle = standaloneResult.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
            as? NSParagraphStyle else {
            return XCTFail("standalone code block has no paragraph style")
        }

        let nestedResult = make("- Item\n\n  ```\n  code line\n  ```")
        let string = nestedResult.string
        let codeStart = (string as NSString).range(of: "code line").location

        guard let codeFont = font(in: nestedResult, at: codeStart) else {
            return XCTFail("nested code block has no font attribute")
        }
        guard let nestedStyle = nestedResult.attribute(.paragraphStyle, at: codeStart, effectiveRange: nil)
            as? NSParagraphStyle else {
            return XCTFail("nested code block has no paragraph style")
        }

        XCTAssertTrue(codeFont.isFixedPitch)
        XCTAssertGreaterThan(nestedStyle.headIndent, standaloneStyle.headIndent)
    }

    /// A fenced code block quoted with `> ` must not sit at the same fixed
    /// indent as a top-level code block either.
    func testCodeBlockNestedInBlockQuoteInheritsQuoteIndent() {
        let standaloneResult = make("```\ncode line\n```")
        guard let standaloneStyle = standaloneResult.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
            as? NSParagraphStyle else {
            return XCTFail("standalone code block has no paragraph style")
        }

        let nestedResult = make("> ```\n> code line\n> ```")
        let string = nestedResult.string
        let codeStart = (string as NSString).range(of: "code line").location

        guard let codeFont = font(in: nestedResult, at: codeStart) else {
            return XCTFail("nested code block has no font attribute")
        }
        guard let nestedStyle = nestedResult.attribute(.paragraphStyle, at: codeStart, effectiveRange: nil)
            as? NSParagraphStyle else {
            return XCTFail("nested code block has no paragraph style")
        }

        XCTAssertTrue(codeFont.isFixedPitch)
        XCTAssertGreaterThan(nestedStyle.headIndent, standaloneStyle.headIndent)
    }

    func testBlockQuoteIsIndentedRelativeToBodyText() {
        let bodyResult = make("Body text")
        guard let bodyStyle = bodyResult.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
            as? NSParagraphStyle else {
            return XCTFail("paragraph has no paragraph style")
        }

        let quoteResult = make("> Quoted text")
        guard let quoteStyle = quoteResult.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
            as? NSParagraphStyle else {
            return XCTFail("block quote has no paragraph style")
        }

        XCTAssertGreaterThan(quoteStyle.headIndent, bodyStyle.headIndent)
    }

    /// A border only actually paints once it has both a nonzero width and a
    /// set color — the running app's bare `NSTextBlock` had both set and
    /// still drew nothing, so the rule is now a 1x1 `NSTextTable` cell border
    /// instead (see `blockQuoteRule`'s doc comment for why). This pins the
    /// visible properties on the block quote's own rule directly, not just
    /// on a list item nested inside one.
    func testBlockQuoteRuleHasAVisibleBorderWidthAndColor() {
        let result = make("> Quoted text")
        guard let style = result.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle,
              let rule = style.textBlocks.first else {
            return XCTFail("block quote carries no text block for its rule")
        }
        XCTAssertGreaterThan(rule.width(for: .border, edge: .minX), 0)
        XCTAssertNotNil(rule.borderColor(for: .minX))
        // The width/color assertions above would also pass a bare `NSTextBlock`
        // configured the same way — exactly the shape that drew nothing in the
        // running app (see `blockQuoteRule`'s doc comment). Only an
        // `NSTextTableBlock` cell is confirmed to actually paint a border.
        XCTAssertTrue(rule is NSTextTableBlock, "block quote rule must be an NSTextTableBlock, not a bare NSTextBlock")
    }

    /// Both an `NSTextBlock` border and a `.thick` underline on a tab run
    /// drew nothing in the running app, even with all the attributes Apple's
    /// docs say are required set (see `renderThematicBreak`'s doc comment) —
    /// so the rule is now an image, embedded as an `NSTextAttachment`.
    /// Neither an attachment's presence nor its image's size proves pixels —
    /// an attribute is not a pixel — so a human still needs to confirm the
    /// actual rendering via `make dev`; this only pins that the attachment
    /// carries an image sized to the full content width and with a nonzero
    /// height, which is what would make the rule visible if TextKit honors it.
    func testThematicBreakProducesAVisibleSeparatorLine() {
        let result = make("Above\n\n---\n\nBelow")
        let attachmentRange = (result.string as NSString).range(of: "\u{FFFC}")
        guard attachmentRange.location != NSNotFound else {
            return XCTFail("no thematic-break attachment found")
        }

        guard let attachment = result.attribute(.attachment, at: attachmentRange.location, effectiveRange: nil)
            as? NSTextAttachment, let image = attachment.image else {
            return XCTFail("thematic break carries no image attachment")
        }

        XCTAssertEqual(image.size.width, contentWidth, accuracy: 0.5)
        XCTAssertGreaterThan(image.size.height, 0)
    }

    /// A thematic break nested inside a block quote (`> ---`) must not sit at
    /// the same zero indent as a top-level one, and its rule must narrow to
    /// fit the space left after that indent rather than overflow past it.
    func testThematicBreakNestedInBlockQuoteInheritsQuoteIndent() {
        let standaloneResult = make("---")
        guard let standaloneStyle = standaloneResult.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
            as? NSParagraphStyle, let standaloneAttachment = standaloneResult.attribute(
                .attachment, at: 0, effectiveRange: nil) as? NSTextAttachment,
            let standaloneImage = standaloneAttachment.image else {
            return XCTFail("standalone thematic break has no paragraph style or image attachment")
        }

        let nestedResult = make("> ---")
        guard let nestedStyle = nestedResult.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
            as? NSParagraphStyle, let nestedAttachment = nestedResult.attribute(
                .attachment, at: 0, effectiveRange: nil) as? NSTextAttachment,
            let nestedImage = nestedAttachment.image else {
            return XCTFail("quoted thematic break has no paragraph style or image attachment")
        }

        XCTAssertGreaterThan(nestedStyle.headIndent, standaloneStyle.headIndent)
        XCTAssertLessThan(nestedImage.size.width, standaloneImage.size.width)
        XCTAssertGreaterThan(nestedImage.size.width, 0)
    }

    func testGFMTableProducesTableBlocksWithDistinguishableHeader() {
        let markdown = """
        | A | B |
        |---|---|
        | 1 | 2 |
        """
        let result = make(markdown)
        let string = result.string

        var cellBlocks: [NSTextTableBlock] = []
        var headerFont: NSFont?
        var bodyFontFound: NSFont?

        for header in ["A", "B", "1", "2"] {
            let range = (string as NSString).range(of: header)
            XCTAssertNotEqual(range.location, NSNotFound, "\(header) missing from table text")

            guard let style = result.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                as? NSParagraphStyle, let block = style.textBlocks.first as? NSTextTableBlock else {
                XCTFail("\(header) cell carries no NSTextTableBlock")
                continue
            }
            cellBlocks.append(block)

            let cellFont = font(in: result, at: range.location)
            if header == "A" || header == "B" {
                headerFont = cellFont
            } else {
                bodyFontFound = cellFont
            }
        }

        XCTAssertEqual(cellBlocks.count, 4)
        // Every cell belongs to the same logical table.
        XCTAssertEqual(Set(cellBlocks.map { ObjectIdentifier($0.table) }).count, 1)

        guard let headerFont, let bodyFontFound else {
            return XCTFail("missing header or body font")
        }
        XCTAssertTrue(NSFontManager.shared.traits(of: headerFont).contains(.boldFontMask))
        XCTAssertFalse(NSFontManager.shared.traits(of: bodyFontFound).contains(.boldFontMask))
    }

    /// A table nested inside a block quote (`> | A | B | ...`) must not sit
    /// at the same zero margin as a top-level table.
    func testTableNestedInBlockQuoteInheritsAmbientIndent() {
        let standaloneMarkdown = """
        | A | B |
        |---|---|
        | 1 | 2 |
        """
        let standaloneResult = make(standaloneMarkdown)
        let standaloneRange = (standaloneResult.string as NSString).range(of: "A")
        guard let standaloneStyle = standaloneResult.attribute(
            .paragraphStyle, at: standaloneRange.location, effectiveRange: nil) as? NSParagraphStyle,
            let standaloneCell = standaloneStyle.textBlocks.first as? NSTextTableBlock else {
            return XCTFail("standalone table cell carries no NSTextTableBlock")
        }
        XCTAssertEqual(standaloneCell.table.width(for: .margin, edge: .minX), 0)

        let nestedMarkdown = """
        > | A | B |
        > |---|---|
        > | 1 | 2 |
        """
        let nestedResult = make(nestedMarkdown)
        let nestedRange = (nestedResult.string as NSString).range(of: "A")
        guard let nestedStyle = nestedResult.attribute(.paragraphStyle, at: nestedRange.location, effectiveRange: nil)
            as? NSParagraphStyle, let nestedCell = nestedStyle.textBlocks.first as? NSTextTableBlock else {
            return XCTFail("quoted table cell carries no NSTextTableBlock")
        }
        XCTAssertGreaterThan(nestedCell.table.width(for: .margin, edge: .minX), 0)
    }

    // MARK: - Realized block geometry

    /// The vertical band a block's own ink occupies once the document is laid
    /// out, in text-container coordinates.
    private struct InkBand {
        let top: CGFloat
        let bottom: CGFloat
    }

    /// Lays `result` out on a real TextKit 2 stack, so a test can read the gaps
    /// a reader actually sees.
    ///
    /// Hand-assembled rather than read off a hosted `NSTextView`, which keeps
    /// this suite off `@MainActor` and needs no `NSHostingView`. A hand-built
    /// stack and a hosted view lay the same content out to identical geometry
    /// as long as both run the same engine — the equivalence
    /// `MarkdownTextView`'s own measurement rests on, and
    /// `WorkspaceInfoPanelTests.testTallMessageKeepsTheFullMeasuredHeightInTheTextView`
    /// is what pins it for TextKit 2, on a table-free message that stays there.
    private func layOut(_ result: NSAttributedString) -> NSTextLayoutManager {
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        let container = NSTextContainer(size: CGSize(width: contentWidth, height: .greatestFiniteMagnitude))
        // Matches the real view's own container, so both wrap at `contentWidth`.
        container.lineFragmentPadding = 0
        contentStorage.addTextLayoutManager(layoutManager)
        layoutManager.textContainer = container
        contentStorage.textStorage?.setAttributedString(result)
        layoutManager.ensureLayout(for: contentStorage.documentRange)
        return layoutManager
    }

    /// The band of ink around the block holding `substring`'s first occurrence.
    ///
    /// A bordered block (a block quote's bar, a GFM table cell) draws its border
    /// around its whole layout fragment, so the fragment's own edges are what
    /// the reader sees — including any `paragraphSpacingBefore` TextKit folded
    /// into that fragment, which is precisely why such spacing opens no gap.
    /// An unbordered block shows only its line fragments, whose first one sits
    /// below whatever spacing the fragment reserved above it.
    private func inkBand(
        around substring: String, in result: NSAttributedString, laidOutBy layout: NSTextLayoutManager
    ) throws -> InkBand {
        let range = (result.string as NSString).range(of: substring)
        XCTAssertNotEqual(range.location, NSNotFound, "no \(substring.debugDescription) in the rendered text")

        let contentManager = try XCTUnwrap(layout.textContentManager)
        let start = try XCTUnwrap(
            contentManager.location(contentManager.documentRange.location, offsetBy: range.location))
        let fragment = try XCTUnwrap(layout.textLayoutFragment(for: start))
        let frame = fragment.layoutFragmentFrame

        let style = paragraphStyle(in: result, at: range.location)
        guard style?.textBlocks.isEmpty == false else {
            let lines = fragment.textLineFragments
            let first = try XCTUnwrap(lines.first)
            let last = try XCTUnwrap(lines.last)
            return InkBand(
                top: frame.minY + first.typographicBounds.minY,
                bottom: frame.minY + last.typographicBounds.maxY)
        }
        return InkBand(top: frame.minY, bottom: frame.maxY)
    }

    // MARK: - Block spacing
    //
    // These assert the relative relationships the popover's one-sided spacing
    // model depends on, not exact point values, so tuning the underlying
    // constants later cannot falsify a test here: every block-to-block gap is
    // the same standard value, a heading's own leading gap is larger than
    // that, consecutive list items are tighter than that, and nothing in this
    // file sets a nonzero trailing ("after") value any more — the realized
    // gap for any pair of adjacent blocks comes from exactly one side.

    /// Regression coverage for the screenshot that started this spacing pass:
    /// a paragraph sat well clear of a thematic-break rule, an even wider gap
    /// opened below the rule, a table's top border touched the paragraph above
    /// it with no visible gap at all, a block quote sat flush under the table
    /// before it, and a list bound tightly to the paragraph after it. Under the
    /// one-sided model every pair of adjacent blocks must open the exact same
    /// gap, regardless of which two block kinds meet.
    ///
    /// Asserted on realized geometry, not on the spacing constants that were
    /// asked for, because those two disagree exactly where this used to break:
    /// a bordered block's `paragraphSpacingBefore` lands *inside* its own
    /// border, and a spacing value set on a separator character mid-paragraph
    /// is never read at all. A style-value assertion sees the values it wanted
    /// in both cases and passes while the reader sees no gap — which is how
    /// this defect shipped under an earlier version of this test.
    ///
    /// The thematic break's *own* height rides along here, since it is the one
    /// block whose fragment a separator newline could inflate unnoticed.
    func testEveryBlockToBlockGapIsTheSameRealizedValue() throws {
        let markdown = """
            Paragraph one.

            ---

            Paragraph two.

            | A |
            |---|
            | 1 |

            > Quoted text

            - Item

            Paragraph three.
            """
        let result = make(markdown)
        let layout = layOut(result)

        let paragraphOne = try inkBand(around: "Paragraph one.", in: result, laidOutBy: layout)
        let thematicBreak = try inkBand(around: "\u{FFFC}", in: result, laidOutBy: layout)
        let paragraphTwo = try inkBand(around: "Paragraph two.", in: result, laidOutBy: layout)
        let tableHeader = try inkBand(around: "A", in: result, laidOutBy: layout)
        let tableBody = try inkBand(around: "1", in: result, laidOutBy: layout)
        let blockQuote = try inkBand(around: "Quoted text", in: result, laidOutBy: layout)
        let listItem = try inkBand(around: "Item", in: result, laidOutBy: layout)
        let paragraphThree = try inkBand(around: "Paragraph three.", in: result, laidOutBy: layout)

        // The rule's own line fragment must stay at the attachment's 1 pt
        // thickness (`Layout.thematicBreakThickness`, private to the renderer, so
        // pinned by value here). `Builder.separator` emits its `"\n"` with no
        // `.font`, so it falls back to Helvetica 12, and that newline terminates
        // *this* paragraph — were TextKit to size the fragment from it, a hairline
        // would reserve a whole body line and the reader would see a tall blank
        // band with a thread through it instead of a separator.
        let ruleHeight = thematicBreak.bottom - thematicBreak.top
        let bodyLineHeight = paragraphOne.bottom - paragraphOne.top
        XCTAssertEqual(
            ruleHeight, 1, accuracy: 0.5,
            "the rule reserves \(ruleHeight) pt against a \(bodyLineHeight) pt body line")

        let gaps = [
            "paragraph → thematic break": thematicBreak.top - paragraphOne.bottom,
            "thematic break → paragraph": paragraphTwo.top - thematicBreak.bottom,
            "paragraph → table": tableHeader.top - paragraphTwo.bottom,
            "table → block quote": blockQuote.top - tableBody.bottom,
            "block quote → list": listItem.top - blockQuote.bottom,
            "list → paragraph": paragraphThree.top - listItem.bottom,
        ]

        let standard = try XCTUnwrap(gaps["paragraph → thematic break"])
        XCTAssertGreaterThan(standard, 0)
        for (transition, gap) in gaps {
            // A point of slack: these are laid-out coordinates, not integers by
            // construction. It is far tighter than the defect it guards, which
            // collapsed a gap to 0 outright.
            XCTAssertEqual(gap, standard, accuracy: 1, "\(transition) opens \(gap) pt against \(standard) pt")
        }
    }

    /// The panel supplies its own leading padding around the message, so the
    /// document's very first block must not reserve a leading gap of its own
    /// — a value here would show as a second, redundant gap above it.
    func testFirstBlockCarriesNoLeadingGap() {
        guard let style = paragraphStyle(in: make("Body text")) else {
            return XCTFail("paragraph has no paragraph style")
        }
        XCTAssertEqual(style.paragraphSpacingBefore, 0)
    }

    /// A table opening the document must reserve no leading gap at all — the
    /// panel supplies its own padding. The gap ahead of a table rides a spacer
    /// paragraph between it and the block before it (see `Builder.separator`),
    /// so "no preceding block" already means "no gap"; this pins that nothing
    /// creeps in ahead of, or between, the header row's cells, which are one
    /// `Block` each and would otherwise be pushed apart into separate lines.
    func testLeadingTableOpensNoGapAndKeepsItsHeaderCellsOnOneRow() {
        let markdown = """
            | A | B |
            |---|---|
            | 1 | 2 |
            """
        let result = make(markdown)

        XCTAssertFalse(result.string.hasPrefix("\n"))
        XCTAssertEqual(result.string, "A\nB\n1\n2")
    }

    /// A larger gap above a heading than the standard block-to-block gap, so
    /// it visibly separates from whatever precedes it. There is no explicit
    /// "after" on a heading any more: the gap below one is simply whatever
    /// standard gap the next block asks for on its own, which stays smaller
    /// than this — so the heading still reads as bound to the text below it.
    func testHeadingSpacingBeforeExceedsTheStandardBlockGap() {
        let headingResult = make("Paragraph.\n\n# Heading")
        guard let headingStyle = paragraphStyle(
            in: headingResult, at: (headingResult.string as NSString).range(of: "Heading").location) else {
            return XCTFail("heading has no paragraph style")
        }
        let paragraphResult = make("Paragraph.\n\nBody text")
        guard let bodyStyle = paragraphStyle(
            in: paragraphResult, at: (paragraphResult.string as NSString).range(of: "Body text").location) else {
            return XCTFail("paragraph has no paragraph style")
        }

        XCTAssertGreaterThan(headingStyle.paragraphSpacingBefore, bodyStyle.paragraphSpacingBefore)
        XCTAssertEqual(headingStyle.paragraphSpacing, 0)
    }

    /// The gap between two list items must read tighter than the gap between
    /// two ordinary blocks, or a list reads as a chain of separate paragraphs
    /// instead of one cohesive block — the bug this spacing pass exists to fix.
    func testConsecutiveListItemSpacingIsTighterThanParagraphSpacing() {
        let result = make("- Item one\n- Item two")
        let secondItemStart = (result.string as NSString).range(of: "Item two").location
        guard let secondItemStyle = paragraphStyle(in: result, at: secondItemStart) else {
            return XCTFail("second list item has no paragraph style")
        }
        let paragraphResult = make("Paragraph.\n\nBody text")
        guard let bodyParagraphStyle = paragraphStyle(
            in: paragraphResult, at: (paragraphResult.string as NSString).range(of: "Body text").location) else {
            return XCTFail("paragraph has no paragraph style")
        }

        XCTAssertLessThan(secondItemStyle.paragraphSpacingBefore, bodyParagraphStyle.paragraphSpacingBefore)
    }

    /// The first item of a list separates the list, as a whole, from whatever
    /// precedes it — every later item stays tight to the one before it instead.
    func testFirstListItemSpacingExceedsSubsequentItemSpacing() {
        let result = make("Paragraph.\n\n- Item one\n- Item two")
        let firstItemStart = (result.string as NSString).range(of: "Item one").location
        let secondItemStart = (result.string as NSString).range(of: "Item two").location
        let firstItemStyle = paragraphStyle(in: result, at: firstItemStart)
        let secondItemStyle = paragraphStyle(in: result, at: secondItemStart)

        guard let firstItemStyle, let secondItemStyle else {
            return XCTFail("a list item has no paragraph style")
        }
        XCTAssertGreaterThan(firstItemStyle.paragraphSpacingBefore, secondItemStyle.paragraphSpacingBefore)
    }

    /// Only the leading side carries a value; trailing ("after") is always 0
    /// under the one-sided model, so the gap below a code block comes from
    /// whatever follows it, not from the code block itself.
    func testCodeBlockCarriesOnlyLeadingSpacing() {
        let result = make("Paragraph.\n\n```\ncode line\n```")
        guard let style = paragraphStyle(in: result, at: (result.string as NSString).range(of: "code line").location)
        else {
            return XCTFail("code block has no paragraph style")
        }
        XCTAssertGreaterThan(style.paragraphSpacingBefore, 0)
        XCTAssertEqual(style.paragraphSpacing, 0)
    }

    /// Regression coverage for the defect this fix exists for: a multi-line
    /// fenced code block arrives from Foundation as a SINGLE run with embedded
    /// `\n` characters (one `Block`, not one per source line), and
    /// `paragraphSpacingBefore` resolves per `\n`-delimited paragraph — so
    /// applying one spaced style across that run's whole range used to open
    /// `Layout.blockSpacingBefore` before every line, not once before the
    /// block. Pinned on realized geometry, not the style values asked for: a
    /// style-value assertion sees the same `paragraphSpacingBefore` in both
    /// the broken and fixed versions and cannot tell them apart.
    ///
    /// The expected total height is derived from a one-line fence's own
    /// realized height (times the line count) rather than a hardcoded point
    /// value, so this cannot be defeated by retuning `Layout` constants later.
    func testMultiLineCodeBlockOpensOnlyOneLeadingGapNotOnePerLine() throws {
        let oneLineResult = make("```\nline\n```")
        let oneLineBand = try inkBand(around: "line", in: oneLineResult, laidOutBy: layOut(oneLineResult))
        let singleLineHeight = oneLineBand.bottom - oneLineBand.top

        let threeLineResult = make("```\nline 1\nline 2\nline 3\n```")
        let layout = layOut(threeLineResult)
        let firstLine = try inkBand(around: "line 1", in: threeLineResult, laidOutBy: layout)
        let lastLine = try inkBand(around: "line 3", in: threeLineResult, laidOutBy: layout)

        // Under the bug this is `3 * singleLineHeight + 2 * Layout.blockSpacingBefore`
        // — one spurious gap between each pair of lines.
        XCTAssertEqual(lastLine.bottom - firstLine.top, singleLineHeight * 3, accuracy: 1)
    }

    /// Same defect, for a paragraph carrying a hard line break (`alpha  \nbeta`,
    /// two trailing spaces) rather than a fenced code block — Foundation
    /// delivers that as one `Block` with an embedded `\n` too, so the same fix
    /// must cover `renderParagraph`, not only `renderCodeBlock`.
    func testParagraphWithHardLineBreakOpensOnlyOneLeadingGap() throws {
        let oneLineResult = make("Paragraph.\n\nalpha")
        let oneLineBand = try inkBand(around: "alpha", in: oneLineResult, laidOutBy: layOut(oneLineResult))
        let singleLineHeight = oneLineBand.bottom - oneLineBand.top

        let brokenResult = make("Paragraph.\n\nalpha  \nbeta")
        let layout = layOut(brokenResult)
        let firstLine = try inkBand(around: "alpha", in: brokenResult, laidOutBy: layout)
        let secondLine = try inkBand(around: "beta", in: brokenResult, laidOutBy: layout)

        // Under the bug this is `2 * singleLineHeight + Layout.blockSpacingBefore`
        // — a spurious gap opening at the hard break.
        XCTAssertEqual(secondLine.bottom - firstLine.top, singleLineHeight * 2, accuracy: 1)
    }

    /// The block quote's own paragraph carries neither side of the standard
    /// gap: either would fold into the same frame the bar's border wraps,
    /// growing the bar past the text it marks (see `renderBlockQuote`'s doc
    /// comment). Its leading gap rides the separator ahead of it instead —
    /// pinned by `testEveryBlockToBlockGapIsTheSameRealizedValue` above.
    func testBlockQuoteOwnParagraphCarriesNoSpacing() {
        guard let style = paragraphStyle(in: make("> Quoted text")) else {
            return XCTFail("block quote has no paragraph style")
        }
        XCTAssertEqual(style.paragraphSpacingBefore, 0)
        XCTAssertEqual(style.paragraphSpacing, 0)
    }

    /// A block quote wrapping to several lines must still get exactly one
    /// `NSTextTableBlock` covering its whole paragraph, not one confined to
    /// its first line, so the bar it draws (see `blockQuoteRule`) spans every
    /// wrapped line — not just the first, the way a misapplied attribute
    /// range would leave it.
    func testBlockQuoteRuleCoversTheFullWrappedParagraph() {
        let longText = Array(repeating: "word", count: 60).joined(separator: " ")
        let result = make("> \(longText)")

        var range = NSRange()
        guard let style = result.attribute(.paragraphStyle, at: 0, effectiveRange: &range) as? NSParagraphStyle,
              !style.textBlocks.isEmpty else {
            return XCTFail("block quote carries no text block for its rule")
        }
        XCTAssertEqual(range, NSRange(location: 0, length: result.length))
    }

    /// Only the leading side carries a value; trailing ("after") is always 0
    /// under the one-sided model, so the gap below the rule comes from
    /// whatever follows it, not from the thematic break itself — the same
    /// mechanism that keeps the gap above and below the rule symmetric.
    func testThematicBreakCarriesOnlyLeadingSpacing() {
        let result = make("Paragraph.\n\n---")
        guard let style = paragraphStyle(in: result, at: (result.string as NSString).range(of: "\u{FFFC}").location)
        else {
            return XCTFail("thematic break has no paragraph style")
        }
        XCTAssertGreaterThan(style.paragraphSpacingBefore, 0)
        XCTAssertEqual(style.paragraphSpacing, 0)
    }

    /// No table cell carries spacing on its own paragraph, header row included:
    /// that paragraph is bordered, and TextKit folds spacing set there inside
    /// the border rather than opening a gap above it (see `Builder.separator`).
    /// The table's clearance from whatever precedes it rides a spacer paragraph
    /// ahead of the header row instead — pinned by
    /// `testEveryBlockToBlockGapIsTheSameRealizedValue` above.
    func testNoTableCellCarriesSpacingOnItsOwnParagraph() {
        let markdown = """
            Paragraph.

            | A | B |
            |---|---|
            | 1 | 2 |
            """
        let result = make(markdown)
        let headerStart = (result.string as NSString).range(of: "A").location
        let bodyStart = (result.string as NSString).range(of: "1").location

        guard let headerStyle = paragraphStyle(in: result, at: headerStart),
              let bodyStyle = paragraphStyle(in: result, at: bodyStart) else {
            return XCTFail("a table cell has no paragraph style")
        }

        XCTAssertEqual(headerStyle.paragraphSpacingBefore, 0)
        XCTAssertEqual(headerStyle.paragraphSpacing, 0)
        XCTAssertEqual(bodyStyle.paragraphSpacingBefore, 0)
        XCTAssertEqual(bodyStyle.paragraphSpacing, 0)
    }

    /// A table row's own vertical padding is per cell, not per row, so a
    /// 3+-row table used to carry a real, easy-to-miss defect: every
    /// non-header row got a trailing gap, stacking an extra one between every
    /// consecutive pair of body rows. Under the one-sided model no row
    /// carries trailing spacing at all — this is regression coverage that
    /// removing "after" everywhere didn't quietly leave a row-level value
    /// behind.
    func testNoTableRowCarriesTrailingSpacing() {
        let markdown = """
            | A |
            |---|
            | 1 |
            | 2 |
            | 3 |
            """
        let result = make(markdown)
        let string = result.string as NSString

        guard let firstRowStyle = paragraphStyle(in: result, at: string.range(of: "1").location),
              let middleRowStyle = paragraphStyle(in: result, at: string.range(of: "2").location),
              let lastRowStyle = paragraphStyle(in: result, at: string.range(of: "3").location) else {
            return XCTFail("a table cell has no paragraph style")
        }

        XCTAssertEqual(firstRowStyle.paragraphSpacing, 0)
        XCTAssertEqual(middleRowStyle.paragraphSpacing, 0)
        XCTAssertEqual(lastRowStyle.paragraphSpacing, 0)
    }

    /// Regression test for a click-targeting bug reported from the running
    /// app: three table rows each hold a distinct link in their second cell,
    /// all three render distinct link text, but clicking any of them opened
    /// the SAME (middle) URL. `.link` is what `NSTextView` hands to
    /// `clickedOnLink:at:`, so each cell's link text must carry its own URL,
    /// not whichever cell happened to render most recently.
    func testGFMTableRowsCarryDistinctLinkURLsPerCell() {
        let markdown = """
            | Name | Link |
            |---|---|
            | a | <http://localhost:48880/> |
            | b | <http://localhost:48881/> |
            | c | <http://localhost:48882/> |
            """
        let result = make(markdown)
        let string = result.string as NSString

        let firstRange = string.range(of: "http://localhost:48880/")
        let secondRange = string.range(of: "http://localhost:48881/")
        let thirdRange = string.range(of: "http://localhost:48882/")
        XCTAssertNotEqual(firstRange.location, NSNotFound)
        XCTAssertNotEqual(secondRange.location, NSNotFound)
        XCTAssertNotEqual(thirdRange.location, NSNotFound)

        let firstURL = result.attribute(.link, at: firstRange.location, effectiveRange: nil) as? URL
        let secondURL = result.attribute(.link, at: secondRange.location, effectiveRange: nil) as? URL
        let thirdURL = result.attribute(.link, at: thirdRange.location, effectiveRange: nil) as? URL

        XCTAssertEqual(firstURL, URL(string: "http://localhost:48880/"))
        XCTAssertEqual(secondURL, URL(string: "http://localhost:48881/"))
        XCTAssertEqual(thirdURL, URL(string: "http://localhost:48882/"))
    }

    /// Same requirement as `testGFMTableRowsCarryDistinctLinkURLsPerCell`, but
    /// for two links inside one bullet list, so the fix can be pinned to the
    /// table renderer instead of the shared inline-run machinery every block
    /// renderer calls.
    func testBulletListItemsCarryDistinctLinkURLs() {
        let markdown = "- [Alpha](http://localhost:1111/)\n- [Beta](http://localhost:2222/)"
        let result = make(markdown)
        let string = result.string as NSString

        let alphaRange = string.range(of: "Alpha")
        let betaRange = string.range(of: "Beta")

        let alphaURL = result.attribute(.link, at: alphaRange.location, effectiveRange: nil) as? URL
        let betaURL = result.attribute(.link, at: betaRange.location, effectiveRange: nil) as? URL

        XCTAssertEqual(alphaURL, URL(string: "http://localhost:1111/"))
        XCTAssertEqual(betaURL, URL(string: "http://localhost:2222/"))
    }

    /// Same requirement again, for two links inside a single paragraph, so the
    /// fix can be pinned to the shared inline-run machinery if the bug turns
    /// out to be general rather than table-specific.
    func testTwoLinksInOneParagraphCarryDistinctLinkURLs() {
        let markdown = "[Alpha](http://localhost:1111/) and [Beta](http://localhost:2222/)"
        let result = make(markdown)
        let string = result.string as NSString

        let alphaRange = string.range(of: "Alpha")
        let betaRange = string.range(of: "Beta")

        let alphaURL = result.attribute(.link, at: alphaRange.location, effectiveRange: nil) as? URL
        let betaURL = result.attribute(.link, at: betaRange.location, effectiveRange: nil) as? URL

        XCTAssertEqual(alphaURL, URL(string: "http://localhost:1111/"))
        XCTAssertEqual(betaURL, URL(string: "http://localhost:2222/"))
    }

    func testImageRendersOnlyItsAltTextWithNoAttachmentOrURL() {
        let result = make("![a description](https://example.com/image.png)")
        let string = result.string

        XCTAssertEqual(string, "a description")
        XCTAssertFalse(string.contains("example.com"))

        result.enumerateAttribute(.attachment, in: NSRange(location: 0, length: result.length)) { value, _, _ in
            XCTAssertNil(value)
        }
    }
}
