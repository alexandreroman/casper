import AppKit

/// Turns Markdown text into a fully styled `NSAttributedString`, so the
/// workspace info panel can host it in a read-only `NSTextView` instead of
/// SwiftUI's `Text` — which puts every link inside one `Text`-backed block
/// with no per-link view to hang a hover cursor off (see the
/// `nstextview-link-cursor-and-selection` project memory note). `NSTextView`
/// gives text selection over that same `.link` attribute; the pointing-hand
/// link cursor is not native to it and is added separately, by
/// `MarkdownTextView.swift`'s `LinkCursorTextView`.
///
/// Parsing goes through Foundation's own Markdown support
/// (`AttributedString(markdown:options:)`) rather than a hand-written parser
/// or a further external dependency, per the project's dependency policy.
/// `.full` syntax turns on GFM extensions (tables, strikethrough, task-list
/// checkboxes); `.returnPartiallyParsedIfPossible` means malformed input
/// still renders something instead of throwing.
///
/// Foundation's parser exposes block structure through a `presentationIntent`
/// attribute on every run: a chain of `PresentationIntent.IntentType`,
/// innermost first, each carrying a stable `identity` shared by every run
/// inside the same block (paragraph, heading, list item, code block, table
/// cell, ...). Grouping runs by their innermost identity recovers block
/// boundaries; the full chain then says which markers, indent, and paragraph
/// style that block needs.
enum MarkdownAttributedString {
    /// Builds a styled `NSAttributedString` for `markdown`, using `font` for
    /// body text and `textColor` for all text. Headings, code, and table/quote
    /// chrome all derive their look from these two rather than introducing
    /// hardcoded colors that could clash with the app's light/dark theme.
    ///
    /// Images (`![alt](url)`) render as their alt text only: the panel makes
    /// no network requests, so no attachment is created and the URL is never
    /// read from the parsed run.
    ///
    /// `contentWidth` is the width the caller will actually lay this text out
    /// at — the thematic break's rule is rasterized to that width (see
    /// `renderThematicBreak`), so it must be the same number the caller uses
    /// both to size its live view and to measure it, or the two fall out of
    /// sync.
    static func make(
        _ markdown: String, font: NSFont, textColor: NSColor, contentWidth: CGFloat
    ) -> NSAttributedString {
        guard !markdown.isEmpty else { return NSAttributedString() }

        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            // `.returnPartiallyParsedIfPossible` already absorbs almost every
            // malformed-input case; this is the last-resort fallback so a
            // truly unparseable string still renders as plain text instead of
            // producing nothing.
            return NSAttributedString(string: markdown, attributes: [.font: font, .foregroundColor: textColor])
        }

        return Builder(font: font, textColor: textColor, contentWidth: contentWidth).build(parsed)
    }
}

/// Named, rationale-carrying layout constants, kept off the render functions
/// so no magic number has to be reverse-engineered from where it is used.
private enum Layout {
    /// GFM defines six heading levels. Scaling down toward 1.0 at h6 keeps the
    /// smallest heading no larger than body text, while h1 stays clearly the
    /// most prominent heading inside the info panel's fixed width.
    static let headingScale: [Int: CGFloat] = [1: 1.6, 2: 1.4, 3: 1.25, 4: 1.15, 5: 1.05, 6: 1.0]

    /// The gap before a heading — deliberately larger than `blockSpacingBefore`
    /// so a heading visibly separates from whatever precedes it. There is no
    /// matching "after" constant: under the one-sided model below, the gap
    /// following a heading is just the *next* block's own standard
    /// `blockSpacingBefore`, smaller than this value, so the heading still
    /// reads as bound to the text it introduces (larger gap above, standard
    /// gap below) without the heading having to set anything on its trailing
    /// side.
    static let headingSpacingBefore: CGFloat = 21

    /// The one gap that separates any two blocks — a paragraph, heading,
    /// list, table, code block, block quote, or thematic break. A live
    /// TextKit 2 stack confirmed this project's paragraph spacing is
    /// additive, not collapsed like a CSS margin: a paragraph's own
    /// `paragraphSpacing` (after) and the next paragraph's
    /// `paragraphSpacingBefore` both add their full value. Setting a value on
    /// *both* sides of a transition made the realized gap the sum of two
    /// constants, which depended on which two block kinds happened to be
    /// neighbors — some pairs doubled up (a rule with a doubled gap below it),
    /// some contributed nothing (a paragraph touching a table's top border
    /// with no visible gap above it), confirmed by a screenshot of the running
    /// app. The fix is structural, not a tuned value: only
    /// the block *below* a transition sets `paragraphSpacingBefore` to this
    /// constant, and nothing in this file sets a nonzero `paragraphSpacing`
    /// (trailing/"after") at all, so every block-to-block gap is this one
    /// value regardless of which two kinds are adjacent. `headingSpacingBefore`
    /// (larger) and `listItemSpacingBefore` (smaller) are the only two
    /// deliberate deviations from it; the document's first block additionally
    /// gets none of it at all (see `Builder.build`'s `isFirstBlock`).
    ///
    /// A block whose own paragraph is bordered — a block quote's bar, a GFM
    /// table's header row — realizes this same value through a different
    /// mechanism, because `paragraphSpacingBefore` does not produce a visible
    /// gap there at all: see `Builder.separator`.
    ///
    /// `paragraphSpacingBefore` is resolved per `\n`-delimited paragraph, not
    /// per attribute run. Foundation hands a multi-line fenced code block —
    /// and a paragraph or list item carrying a hard line break — to this file
    /// as a SINGLE run with embedded `\n` characters, so applying one spaced
    /// style across that run's whole range opens the gap before every line
    /// it contains, not once before the block. Any renderer whose block can
    /// contain an embedded newline must instead apply this value to only the
    /// block's first paragraph and a zero-spacing copy to the rest — see
    /// `Builder.applyLeadingSpacing`.
    static let blockSpacingBefore: CGFloat = 12

    /// Point size of the font carried by the spacer paragraph that opens the
    /// gap above a bordered block (see `Builder.separator`). That paragraph
    /// holds no glyphs, and its `minimum`/`maximumLineHeight` already fix its
    /// height exactly — this only keeps the metrics underneath from asking for
    /// a full line of body-text ascent/descent that the fixed height then has
    /// to fight, the same reasoning as `thematicBreakThickness`'s second job on
    /// the rule's own run.
    static let spacerFontSize: CGFloat = 1

    /// The gap above every list item after the first, in the same list — much
    /// tighter than `blockSpacingBefore`, so the list reads as one cohesive
    /// block instead of a chain of separate paragraphs (the bug this spacing
    /// pass exists to fix). The first item uses `blockSpacingBefore` itself,
    /// like any other block, so the list as a whole reads like any other
    /// block from the outside.
    static let listItemSpacingBefore: CGFloat = 3

    /// One indent step per list nesting level, wide enough to clear a
    /// two-digit ordered-list marker ("10.") without crowding the item text.
    static let indentStep: CGFloat = 18

    /// Extra indent, past a list item's marker column, so a wrapped line
    /// aligns under the item's text rather than under its marker.
    static let listHangingIndent: CGFloat = 16

    /// The bullet glyph for an unordered list item.
    static let bulletGlyph = "•"
    static let uncheckedGlyph = "☐"
    static let checkedGlyph = "☑"

    /// Indent applied to a block quote per nesting level — also the distance
    /// between the bar (`blockQuoteRule`, drawn at the cell's own left edge)
    /// and the text it marks, so this stays deliberately narrow: a running
    /// screenshot showed the text sitting far to the right of the bar at a
    /// wider value, reading as two unrelated elements instead of one.
    static let blockQuoteIndent: CGFloat = 6

    /// Width of the block quote's leading rule, drawn as a 1x1 `NSTextTable`
    /// cell border (see `blockQuoteRule`). Kept narrow relative to
    /// `blockQuoteIndent`/`indentStep` so the table cell that draws it cannot
    /// meaningfully double up with the paragraph's own `headIndent`. The
    /// thematic break's rule is a separate, rasterized-image technique with
    /// its own thickness constant (see `thematicBreakThickness` and
    /// `renderThematicBreak`) rather than a text-block border, so this
    /// constant does not apply to it.
    static let ruleWidth: CGFloat = 2

    /// Indent applied to a fenced code block — its own constant, not tied to
    /// `blockQuoteIndent`, since a code block has no leading bar whose gap to
    /// the text needs to stay narrow the way the block quote's does.
    static let codeBlockIndent: CGFloat = 14

    /// Alpha blended into `textColor` to derive chrome (rules, borders, code
    /// background) that reads correctly in both light and dark themes without
    /// a second color parameter on `make`.
    static let chromeAlpha: CGFloat = 0.35
    static let codeBackgroundAlpha: CGFloat = 0.08

    /// Table cell border width and inner padding.
    static let tableBorderWidth: CGFloat = 1
    static let tableCellPadding: CGFloat = 6

    /// Thickness of the thematic break's rule, drawn as a rasterized image
    /// embedded via `NSTextAttachment` (see `renderThematicBreak`). Also
    /// doubles as the point size of the `.font` attribute carried by the
    /// attachment's own run, so the line fragment TextKit reserves around it
    /// stays close to the rule's own thickness instead of a full line of
    /// body-text ascent/descent wrapped around a hairline image.
    static let thematicBreakThickness: CGFloat = 1
}

/// Font derivations shared by every block renderer. `NSFontManager` is the
/// standard AppKit way to add traits (bold, italic) to an arbitrary base font
/// without assuming it is a system font.
///
/// Memoized for the lifetime of one `make` call, because every inline run asks
/// for the face its emphasis needs while a document draws from a handful of
/// base fonts (body, one per heading level, the bold table-header face) times
/// the four trait combinations. A reference type, so the `Builder` value that
/// owns one can fill it in from its non-mutating render methods.
private final class Fonts {
    private var cache: [Key: NSFont] = [:]

    private struct Key: Hashable {
        let base: NSFont
        /// `NSFontTraitMask.rawValue`, or `nil` for the monospaced derivation —
        /// which swaps the family outright rather than adding a trait.
        let traits: UInt?
    }

    func applying(_ traits: NSFontTraitMask, to base: NSFont) -> NSFont {
        guard !traits.isEmpty else { return base }
        return derived(Key(base: base, traits: traits.rawValue)) {
            NSFontManager.shared.convert(base, toHaveTrait: traits)
        }
    }

    func bold(_ base: NSFont) -> NSFont {
        applying(.boldFontMask, to: base)
    }

    func monospaced(_ base: NSFont) -> NSFont {
        derived(Key(base: base, traits: nil)) {
            NSFont.monospacedSystemFont(ofSize: base.pointSize, weight: .regular)
        }
    }

    /// Not memoized: one heading block asks for one resize, so a cache entry
    /// would never be read twice.
    static func resized(_ base: NSFont, to size: CGFloat) -> NSFont {
        NSFont(descriptor: base.fontDescriptor, size: size) ?? base
    }

    private func derived(_ key: Key, _ make: () -> NSFont) -> NSFont {
        if let cached = cache[key] { return cached }
        let font = make()
        cache[key] = font
        return font
    }
}

/// One paragraph-shaped unit of parsed text: every run between two
/// block-boundary identity changes, plus the presentation-intent chain
/// (innermost first) describing what kind of block it is and how it nests.
private struct Block {
    let components: [PresentationIntent.IntentType]
    var runs: [(text: String, inline: InlinePresentationIntent, link: URL?)] = []
}

/// Every predicate below walks `components` directly. A shared
/// `components.map(\.kind)` would read better but allocates an array per
/// access, and one block's render reads about a dozen of these.
private extension Block {
    var headerLevel: Int? {
        for component in components { if case .header(let level) = component.kind { return level } }
        return nil
    }

    var isCodeBlock: Bool {
        components.contains { if case .codeBlock = $0.kind { return true }; return false }
    }

    var isThematicBreak: Bool {
        components.contains { if case .thematicBreak = $0.kind { return true }; return false }
    }

    var isBlockQuote: Bool {
        components.contains { if case .blockQuote = $0.kind { return true }; return false }
    }

    var isOrderedList: Bool {
        components.contains { if case .orderedList = $0.kind { return true }; return false }
    }

    var listItemOrdinal: Int? {
        for component in components { if case .listItem(let ordinal) = component.kind { return ordinal } }
        return nil
    }

    /// Nesting depth used for indentation: one level per ancestor list item.
    var listDepth: Int {
        components.count { if case .listItem = $0.kind { return true }; return false }
    }

    var quoteDepth: Int {
        components.count { if case .blockQuote = $0.kind { return true }; return false }
    }

    var isTableHeaderRow: Bool {
        components.contains { if case .tableHeaderRow = $0.kind { return true }; return false }
    }

    var tableRowIndex: Int? {
        for component in components { if case .tableRow(let rowIndex) = component.kind { return rowIndex } }
        return nil
    }

    var tableColumnIndex: Int? {
        for component in components { if case .tableCell(let columnIndex) = component.kind { return columnIndex } }
        return nil
    }

    /// The enclosing table's stable identity and column count. The identity
    /// lives on the `IntentType` rather than on its `kind`, and every cell of
    /// the same table needs to share it.
    var table: (identity: Int, columnCount: Int)? {
        for component in components {
            if case .table(let columns) = component.kind {
                return (component.identity, columns.count)
            }
        }
        return nil
    }

    /// The indent a block inherits from whatever it is nested inside: one step
    /// per ancestor list item, one quote indent per ancestor block quote.
    /// Composed by every renderer that draws its own chrome on top of it, so
    /// that a code fence, a rule or a table under `- ` / `> ` keeps its
    /// ancestors' offset.
    var ambientIndent: CGFloat {
        CGFloat(listDepth) * Layout.indentStep + CGFloat(quoteDepth) * Layout.blockQuoteIndent
    }

    /// True exactly for the two block kinds that draw a block quote's leading
    /// bar — `renderBlockQuote`, and a `renderListItem` whose item is itself
    /// quoted — mirroring `render(_:tables:isFirstBlock:)`'s own dispatch
    /// priority: those two are reached only once thematic break, table cell,
    /// header, and code block have already been ruled out. One of the two
    /// predicates `Builder.separator` reads to spot a block whose own
    /// paragraph is bordered, and whose leading gap therefore cannot sit on
    /// that paragraph.
    var hasBlockQuoteRule: Bool {
        guard isBlockQuote else { return false }
        return !isThematicBreak && table == nil && headerLevel == nil && !isCodeBlock
    }

    /// True for a header cell of a GFM table that `previous` is not already
    /// part of — that is, for the row that opens a new table's border box.
    /// The other predicate `Builder.separator` reads: every header cell's
    /// paragraph is bordered, but only the transition *into* the table needs a
    /// gap ahead of it, so this compares table identities rather than testing
    /// `isTableHeaderRow` alone — the header row is one `Block` per cell, and
    /// a gap ahead of each of them would push blank paragraphs between the
    /// cells of a single row.
    func opensTableBorder(after previous: Block) -> Bool {
        guard isTableHeaderRow, let table else { return false }
        return previous.table?.identity != table.identity
    }
}

/// Assembles one document's worth of blocks into a single `NSAttributedString`.
/// It exists only for the duration of one `make` call, and carries no state
/// beyond the three styling inputs it was given and the font derivations it
/// memoizes along the way.
private struct Builder {
    let font: NSFont
    let textColor: NSColor
    /// The width the caller lays this text out at, needed only to size the
    /// thematic break's rasterized rule (see `renderThematicBreak`).
    let contentWidth: CGFloat
    /// Scoped to this build, so nothing outlives the call — see `Fonts`.
    let fonts = Fonts()

    func build(_ text: AttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var tables: [Int: NSTextTable] = [:]
        let blocks = groupIntoBlocks(text)

        for (index, block) in blocks.enumerated() {
            // The separator joining this block to the previous one, not a
            // trailing one after it: appending "before" means the document's
            // last block leaves no spurious separator to trim afterwards. Its
            // absence ahead of block 0 is also what exempts a leading bordered
            // block from the gap, the way `isFirstBlock` does for every other
            // block kind.
            if index > 0 {
                result.append(separator(before: block, after: blocks[index - 1]))
            }
            result.append(render(block, tables: &tables, isFirstBlock: index == 0))
        }
        return result
    }

    /// What joins one block to the block before it.
    ///
    /// A bare `"\n"` for most blocks: their own gap already rides their
    /// `paragraphSpacingBefore`, the standard one-sided mechanism (see
    /// `Layout.blockSpacingBefore`).
    ///
    /// **A block whose own paragraph is bordered needs its own paragraph for
    /// the gap instead**, because neither spacing attribute can produce a
    /// visible one there. TextKit folds a paragraph's `paragraphSpacingBefore`
    /// into the very `layoutFragmentFrame` an `NSTextTableBlock` border wraps,
    /// so a bordered block asking for its own leading gap grows its border box
    /// upwards over that gap rather than opening space above it — measured, for
    /// both a block quote's bar and a GFM table's header row, as a border edge
    /// touching the preceding paragraph's last line with nothing between them.
    /// Moving that value onto this separator's own `"\n"` does not help either:
    /// a paragraph is delimited by newlines, not by attribute runs, so that
    /// `"\n"` is the *last character of the preceding block's* paragraph, whose
    /// style TextKit resolves from its first character — the spacing set here
    /// was simply never read (measured: 0 pt realized against 12 pt asked).
    ///
    /// So the gap is emitted as real, occupied height instead of as a spacing
    /// value that something downstream can fold away: a second `"\n"` making a
    /// paragraph of its own, carrying a tiny font and a fixed line height (see
    /// `Layout.spacerFontSize`) so its line fragment is exactly `gap` tall.
    /// Being its own paragraph, and an unbordered one, it sits outside the
    /// following block's border box — which is the whole point. Do not
    /// "simplify" this back into a spacing attribute on either neighboring
    /// paragraph; that is the shape that collapses.
    private func separator(before block: Block, after previous: Block) -> NSAttributedString {
        guard let gap = borderedLeadingGap(before: block, after: previous) else {
            return NSAttributedString(string: "\n")
        }
        let style = NSMutableParagraphStyle()
        // Both bounds, so the line is exactly `gap` tall whatever metrics the
        // font underneath would otherwise ask for.
        style.minimumLineHeight = gap
        style.maximumLineHeight = gap

        let separator = NSMutableAttributedString(string: "\n")
        separator.append(NSAttributedString(string: "\n", attributes: [
            .paragraphStyle: style,
            .font: NSFont.systemFont(ofSize: Layout.spacerFontSize),
        ]))
        return separator
    }

    /// The gap a block whose own leading paragraph carries `.textBlocks` needs
    /// ahead of it, or `nil` for an ordinary block that carries its gap itself.
    /// The two cases are the block quote's bar and a GFM table's header row;
    /// each keeps whatever value the equivalent unbordered block would have
    /// asked for, so a bordered block is not a spacing exception — only a
    /// mechanism one. A quoted list item in particular mirrors
    /// `renderListItem`'s own before/after-first rule.
    private func borderedLeadingGap(before block: Block, after previous: Block) -> CGFloat? {
        if block.hasBlockQuoteRule {
            guard let ordinal = block.listItemOrdinal else { return Layout.blockSpacingBefore }
            return ordinal == 1 ? Layout.blockSpacingBefore : Layout.listItemSpacingBefore
        }
        if block.opensTableBorder(after: previous) {
            return Layout.blockSpacingBefore
        }
        return nil
    }

    // MARK: - Grouping

    private func groupIntoBlocks(_ text: AttributedString) -> [Block] {
        var blocks: [Block] = []
        var lastIdentity: Int?

        for run in text.runs {
            let runText = String(text[run.range].characters)
            guard !runText.isEmpty else { continue }

            let components = run.presentationIntent?.components ?? []
            let identity = components.first?.identity

            if blocks.isEmpty || identity != lastIdentity {
                blocks.append(Block(components: components))
                lastIdentity = identity
            }
            blocks[blocks.count - 1].runs.append(
                (text: runText, inline: run.inlinePresentationIntent ?? [], link: run.link))
        }
        return blocks
    }

    // MARK: - Block dispatch

    /// Priority order for a block that satisfies more than one predicate
    /// (e.g. `> - item` is both a block quote and a list item, `> | A | B |`
    /// is both a block quote and a table cell). Foundation nests all of
    /// thematic break, table cell, and header under a list/quote just as
    /// readily as it nests a paragraph or a code block — verified directly
    /// against the parser, not assumed. Table cell and thematic break each
    /// read `quoteDepth`/`listDepth` themselves and compose the ambient
    /// indent (see `renderTableCell`, `renderThematicBreak`), so which
    /// branch of this if-chain a block takes does not cost it that chrome.
    /// Header is the one deliberate exception: this renderer does not
    /// compose list/quote chrome onto a heading, because a heading nested
    /// inside a list or quote is rare in the panel's own messages and
    /// untested — it renders as a standalone heading instead. Everything
    /// else — code block, list item, block quote, plain paragraph —
    /// composes `quoteDepth`/`listDepth` into its own indent the same way
    /// (see `renderListItem` and `renderCodeBlock`).
    private func render(
        _ block: Block, tables: inout [Int: NSTextTable], isFirstBlock: Bool
    ) -> NSAttributedString {
        if block.isThematicBreak {
            return renderThematicBreak(block, isFirstBlock: isFirstBlock)
        }
        if let column = block.tableColumnIndex, let table = block.table {
            return renderTableCell(block, column: column, table: table, tables: &tables)
        }
        if let level = block.headerLevel {
            return renderHeading(block, level: level, isFirstBlock: isFirstBlock)
        }
        if block.isCodeBlock {
            return renderCodeBlock(block, isFirstBlock: isFirstBlock)
        }
        if let ordinal = block.listItemOrdinal {
            return renderListItem(block, ordinal: ordinal, isFirstBlock: isFirstBlock)
        }
        if block.isBlockQuote {
            return renderBlockQuote(block)
        }
        return renderParagraph(block, isFirstBlock: isFirstBlock)
    }

    /// The value every renderer below passes as its own `paragraphSpacingBefore`,
    /// zeroed for the document's first block — the panel already supplies its
    /// own leading padding around the message, so a value here would open a
    /// second, redundant gap on top of it (`isFirstBlock` is computed once, in
    /// `build`, precisely so every renderer applies this the same way).
    private func spacingBefore(_ standard: CGFloat, isFirstBlock: Bool) -> CGFloat {
        isFirstBlock ? 0 : standard
    }

    /// The tail every unbordered block shares: indent both head indents by
    /// `indent`, open `spacingBefore` above the block, and hand the result to
    /// `applyLeadingSpacing` so the gap lands on the block's first paragraph
    /// only. Returns `text`, styled in place.
    ///
    /// A block that needs more of the style than this — a list item's hanging
    /// indent and tab stop, a bordered block's `textBlocks` — builds its own.
    private func styled(
        _ text: NSMutableAttributedString, indent: CGFloat, spacingBefore: CGFloat
    ) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        style.paragraphSpacingBefore = spacingBefore
        applyLeadingSpacing(style, to: text)
        return text
    }

    /// Applies `style` to `text`'s first `\n`-delimited paragraph only, and a
    /// zero-`paragraphSpacingBefore` copy of it to whatever paragraphs follow
    /// — see `Layout.blockSpacingBefore`'s doc comment for why a single style
    /// cannot simply cover the whole range. Every other property of `style`
    /// (indent, tab stops, text blocks) is preserved on both paragraphs, so
    /// only the leading gap itself is confined to the block's first line.
    ///
    /// A range with no interior `\n` (the common case: most blocks are one
    /// paragraph) takes the fast path of covering the whole range with
    /// `style` unchanged.
    private func applyLeadingSpacing(_ style: NSMutableParagraphStyle, to text: NSMutableAttributedString) {
        let firstNewline = (text.string as NSString).range(of: "\n").location
        let firstParagraphLength = firstNewline == NSNotFound ? text.length : firstNewline + 1

        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: firstParagraphLength))
        guard firstParagraphLength < text.length else { return }

        let rest = style.mutableCopy() as! NSMutableParagraphStyle
        rest.paragraphSpacingBefore = 0
        text.addAttribute(
            .paragraphStyle, value: rest,
            range: NSRange(location: firstParagraphLength, length: text.length - firstParagraphLength))
    }

    /// Applies `style` to the whole of `text`, for a block that is **one**
    /// paragraph by construction — a heading, a block quote, a table cell. There
    /// is no following paragraph to keep the leading gap off, which is the only
    /// thing `applyLeadingSpacing` exists to arrange, so the split it performs
    /// would be dead work here.
    private func applyThroughout(_ style: NSParagraphStyle, to text: NSMutableAttributedString) {
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
    }

    // MARK: - Inline runs

    /// Renders a block's runs with their inline emphasis (bold, italic, code,
    /// strikethrough, links) applied, but no paragraph-level style yet.
    private func inlineAttributedText(_ block: Block, baseFont: NSFont) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        for run in block.runs {
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: textColor]

            if run.inline.contains(.code) {
                attributes[.font] = fonts.monospaced(baseFont)
            } else {
                var traits: NSFontTraitMask = []
                if run.inline.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
                if run.inline.contains(.emphasized) { traits.insert(.italicFontMask) }
                attributes[.font] = fonts.applying(traits, to: baseFont)
            }

            if run.inline.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link {
                attributes[.link] = link
            }

            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return result
    }

    // MARK: - Block renderers

    private func renderParagraph(_ block: Block, isFirstBlock: Bool) -> NSAttributedString {
        // A paragraph carrying a hard line break (`alpha␣␣\nbeta`) arrives as
        // one run with an embedded `\n`; see `applyLeadingSpacing`.
        styled(
            inlineAttributedText(block, baseFont: font), indent: 0,
            spacingBefore: spacingBefore(Layout.blockSpacingBefore, isFirstBlock: isFirstBlock))
    }

    private func renderHeading(_ block: Block, level: Int, isFirstBlock: Bool) -> NSAttributedString {
        let scale = Layout.headingScale[level] ?? 1.0
        let headingFont = fonts.bold(Fonts.resized(font, to: font.pointSize * scale))

        return styled(
            inlineAttributedText(block, baseFont: headingFont), indent: 0,
            spacingBefore: spacingBefore(Layout.headingSpacingBefore, isFirstBlock: isFirstBlock))
    }

    private func renderListItem(_ block: Block, ordinal: Int, isFirstBlock: Bool) -> NSAttributedString {
        let text = inlineAttributedText(block, baseFont: font)
        let marker = taskMarker(strippingFrom: text) ?? (block.isOrderedList ? "\(ordinal)." : Layout.bulletGlyph)

        let paragraph = NSMutableAttributedString(
            string: marker + "\t", attributes: [.font: font, .foregroundColor: textColor])
        paragraph.append(text)

        // A list item nested inside a block quote (`> - item`, or a list
        // whose item itself starts with `> ...`) keeps the quote's indent and
        // leading rule on top of its own marker and hanging indent, instead
        // of the quote's chrome being dropped because this branch runs first
        // in `render(_:tables:isFirstBlock:)`.
        let indent = block.ambientIndent

        // Its own style rather than `styled(_:indent:spacingBefore:)`: an item's
        // text hangs past its marker, and a quoted one carries the bar.
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = indent
        style.headIndent = indent + Layout.listHangingIndent
        style.tabStops = [NSTextTab(textAlignment: .left, location: style.headIndent)]
        if block.isBlockQuote {
            // This item's leading gap rides the separator ahead of it instead
            // (`Block.hasBlockQuoteRule`, `Builder.separator`), so the bar it
            // shares with `renderBlockQuote` wraps only its own text.
            style.paragraphSpacingBefore = 0
            style.textBlocks = [blockQuoteRule()]
        } else {
            // Only the first item pays the full block-level gap that separates
            // the list from whatever precedes it; every later item stays tight
            // to the one before it so the list reads as one block, not a chain
            // of blocks.
            style.paragraphSpacingBefore = ordinal == 1
                ? spacingBefore(Layout.blockSpacingBefore, isFirstBlock: isFirstBlock)
                : Layout.listItemSpacingBefore
        }
        // A list item carrying a hard line break arrives as one run with an
        // embedded `\n`, same as a plain paragraph; see `applyLeadingSpacing`.
        applyLeadingSpacing(style, to: paragraph)
        return paragraph
    }

    /// GFM task-list checkboxes arrive as literal `[ ] ` / `[x] ` text at the
    /// start of a list item — Foundation's Markdown parser has no dedicated
    /// intent for them. This swaps that literal prefix for a checkbox glyph
    /// and reports which one, mutating `text` in place; an ordinary list item
    /// is left untouched and this returns `nil`.
    private func taskMarker(strippingFrom text: NSMutableAttributedString) -> String? {
        let markers: [(prefix: String, glyph: String)] = [
            ("[ ] ", Layout.uncheckedGlyph),
            ("[x] ", Layout.checkedGlyph),
            ("[X] ", Layout.checkedGlyph),
        ]
        // Hoisted: `text.string` materializes the whole backing store, and the
        // loop would otherwise pay for that once per marker to test four ASCII
        // characters.
        let string = text.string
        for (prefix, glyph) in markers where string.hasPrefix(prefix) {
            text.deleteCharacters(in: NSRange(location: 0, length: prefix.utf16.count))
            return glyph
        }
        return nil
    }

    private func renderBlockQuote(_ block: Block) -> NSAttributedString {
        let text = inlineAttributedText(block, baseFont: font)
        let indent = block.ambientIndent

        let style = NSMutableParagraphStyle()
        style.headIndent = indent
        style.firstLineHeadIndent = indent
        // No `paragraphSpacingBefore`/`paragraphSpacing` here: this paragraph
        // also carries `textBlocks`, and TextKit folds spacing-before into the
        // same `layoutFragmentFrame` the bar's border wraps (see
        // `blockQuoteRule`'s doc comment) — setting either would push the bar
        // above the first line and, on a quote wrapping to several lines,
        // leave it the wrong height for the rest of them. This block's own
        // leading gap rides the separator ahead of it instead; see
        // `Builder.separator` and `Block.hasBlockQuoteRule`.
        style.textBlocks = [blockQuoteRule()]
        applyThroughout(style, to: text)
        return text
    }

    /// A hairline rule to the left of a block quote, independent of the
    /// paragraph's own `headIndent` (see `Layout.ruleWidth`). Shared by
    /// `renderBlockQuote` and `renderListItem`, so a list item nested inside
    /// a quote gets the same rule as a plain quoted paragraph. `NSTextTable`
    /// treats the whole paragraph as one row/cell regardless of how many
    /// lines it wraps into, so this single cell already spans every wrapped
    /// line of a multi-line quote, not just its first.
    ///
    /// This used to be a bare `NSTextBlock` with both width and color set on
    /// its border, which is the configuration Apple's own docs say is
    /// required — and it still drew nothing in the running app. `NSTextBlock`
    /// and `NSTextTable` border rendering has multiple open, Apple-acknowledged
    /// AppKit bugs independent of this app's code (e.g. FB16391696: table
    /// borders intermittently fail to draw, traced to a *margin* being set on
    /// the block; FB15162186: `NSTextList` not rendering on macOS at all).
    /// Pixel-level headless verification could not settle this either way —
    /// an offscreen `cacheDisplay` render of the GFM table (the one construct
    /// already confirmed visibly correct on screen) produced no detectable
    /// border pixels, so the technique cannot distinguish "broken" from "not
    /// observable this way" for anything in this family. What this rewrite
    /// does do: switch to a `NSTextTableBlock` cell, which is the same
    /// object the GFM table's own (confirmed-visible) cell borders use, and
    /// — per the margin finding above — deliberately set no margin on it.
    private func blockQuoteRule() -> NSTextBlock {
        let table = NSTextTable()
        table.numberOfColumns = 1
        let rule = NSTextTableBlock(table: table, startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)
        rule.setWidth(Layout.ruleWidth, type: .absoluteValueType, for: .border, edge: .minX)
        rule.setBorderColor(textColor.withAlphaComponent(Layout.chromeAlpha), for: .minX)
        return rule
    }

    private func renderCodeBlock(_ block: Block, isFirstBlock: Bool) -> NSAttributedString {
        let codeFont = fonts.monospaced(font)
        var text = block.runs.map(\.text).joined()
        // The parser's own trailing newline would otherwise stack with the
        // block separator `build` appends, leaving a spurious blank line.
        if text.hasSuffix("\n") { text.removeLast() }

        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: codeFont,
            .foregroundColor: textColor,
            .backgroundColor: textColor.withAlphaComponent(Layout.codeBackgroundAlpha),
        ])

        // A code block nested inside a list item or a block quote (a fence
        // indented under `- ` or quoted with `> `) adds that ancestor's
        // indent on top of the block's own base indent, instead of sitting at
        // the same fixed indent as a top-level code block.
        //
        // The whole fence is one run with an embedded `\n` per source line —
        // exactly the case `applyLeadingSpacing` exists to handle, so the gap
        // opens once before the block instead of before every line.
        return styled(
            attributed, indent: Layout.codeBlockIndent + block.ambientIndent,
            spacingBefore: spacingBefore(Layout.blockSpacingBefore, isFirstBlock: isFirstBlock))
    }

    private func renderThematicBreak(_ block: Block, isFirstBlock: Bool) -> NSAttributedString {
        // Foundation's own thematic-break run is a single "⸻" glyph; a real
        // full-width rule reads as a much clearer separator than one
        // character, so that text is discarded in favor of drawing the rule
        // directly.
        //
        // Two earlier techniques were both tried against the running app and
        // both drew nothing, confirmed by screenshot — neither should be
        // reintroduced:
        //   1. A bare `NSTextBlock` border, with both a width and a color set
        //      on one edge (the configuration Apple's own docs say is
        //      required) — see `blockQuoteRule`'s doc comment for the wider
        //      AppKit border-rendering bugs this points to.
        //   2. A `.thick` `.underlineStyle` on a tab run stretched by a
        //      far-out tab stop — still invisible, leaving only the reserved
        //      line height as a tall blank gap where the rule should be.
        //      Underlining a tab's whitespace advance is evidently not a
        //      drawn glyph the way underlining actual text is.
        // Both are attribute/border compositing paths with open AppKit gaps.
        // An embedded image is a different, well-supported path instead —
        // `NSTextAttachment` composites like any inline image — so the rule
        // below is rasterized into a 1pt-tall `NSImage` and embedded that way.
        let indent = block.ambientIndent
        let ruleWidth = max(contentWidth - indent, 1)

        let attachment = NSTextAttachment()
        attachment.image = ruleImage(width: ruleWidth)
        attachment.bounds = CGRect(x: 0, y: 0, width: ruleWidth, height: Layout.thematicBreakThickness)

        let text = NSMutableAttributedString(attachment: attachment)
        // A tiny font on the attachment run itself, not the body font:
        // TextKit sizes an attachment-only line fragment from the larger of
        // the attachment's own bounds and its run's font metrics, so
        // inheriting the body font here would reserve a full line of
        // ascent/descent around a 1pt image — the same "tall blank gap" the
        // underline attempt above already left behind.
        text.addAttribute(
            .font, value: NSFont.systemFont(ofSize: Layout.thematicBreakThickness),
            range: NSRange(location: 0, length: text.length))
        return styled(
            text, indent: indent,
            spacingBefore: spacingBefore(Layout.blockSpacingBefore, isFirstBlock: isFirstBlock))
    }

    /// Rasterizes the thematic break's rule so it can ride as an
    /// `NSTextAttachment` image (see `renderThematicBreak` for why this
    /// technique was chosen over a text-block border or an underline).
    private func ruleImage(width: CGFloat) -> NSImage {
        let color = textColor.withAlphaComponent(Layout.chromeAlpha)
        return NSImage(size: NSSize(width: width, height: Layout.thematicBreakThickness), flipped: false) { rect in
            color.setFill()
            rect.fill()
            return true
        }
    }

    private func renderTableCell(
        _ block: Block,
        column: Int,
        table tableInfo: (identity: Int, columnCount: Int),
        tables: inout [Int: NSTextTable]
    ) -> NSAttributedString {
        let table = tables[tableInfo.identity] ?? {
            let table = NSTextTable()
            table.numberOfColumns = tableInfo.columnCount
            // A table nested inside a list item or block quote (`- | A | B |`,
            // `> | A | B |`) keeps that ancestor's indent, set once on the
            // shared table's own margin rather than per cell: every cell of
            // one table shares the same ambient nesting, and `NSTextTable`
            // (itself an `NSTextBlock`) carries a margin independent of each
            // cell's own border/padding, verified against a live table/cell
            // pair before relying on it here.
            let ambientIndent = block.ambientIndent
            if ambientIndent > 0 {
                table.setWidth(ambientIndent, type: .absoluteValueType, for: .margin, edge: .minX)
            }
            tables[tableInfo.identity] = table
            return table
        }()

        let isHeader = block.isTableHeaderRow
        // Foundation numbers body rows starting past the header (the header
        // itself has no numeric row), so a body `tableRowIndex` already lines
        // up with the table's own row grid; only the header needs row 0.
        let row = isHeader ? 0 : (block.tableRowIndex ?? 0)

        let cellBlock = NSTextTableBlock(
            table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
        cellBlock.setWidth(Layout.tableBorderWidth, type: .absoluteValueType, for: .border)
        cellBlock.setBorderColor(textColor.withAlphaComponent(Layout.chromeAlpha))
        cellBlock.setWidth(Layout.tableCellPadding, type: .absoluteValueType, for: .padding)

        let cellFont = isHeader ? fonts.bold(font) : font
        let text = inlineAttributedText(block, baseFont: cellFont)

        let style = NSMutableParagraphStyle()
        // No spacing on either side of any cell, header or body. This paragraph
        // is bordered, so a leading gap set here would grow the border box
        // upwards over the gap instead of opening it (see `Builder.separator`);
        // the table's clearance from whatever precedes it rides the spacer
        // paragraph ahead of its header row instead. The gap *below* the table
        // comes from whatever block follows it asking for its own standard
        // "before", exactly like a table following any other block kind.
        style.textBlocks = [cellBlock]
        applyThroughout(style, to: text)
        return text
    }
}
