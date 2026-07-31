import AppKit
import CasperGit

/// The diff's gutter: per visible row a tint band, a 3 pt accent stripe flush
/// against the leading edge, and the line number, right-aligned.
///
/// A ruler view rather than a second text column, because the numbers must stay
/// *outside* the text storage: selecting twenty lines then copies twenty lines of
/// code and nothing else — no numbers, no gutter padding — which the row-based
/// renderer could not offer at all.
///
/// Rows are placed by `DiffFragmentGeometry`, the same reader `DiffTextView` uses
/// for its tints, so the stripe and the code it belongs to cannot drift apart.
final class DiffGutterRuler: NSRulerView {
    /// Width of the accent stripe hugging the leading edge, as in the row-based
    /// renderer.
    static let stripeWidth: CGFloat = 3

    /// Distance from the line number's right edge to where the code's glyphs
    /// start. The row-based renderer spaced its two columns by exactly this (an
    /// `HStack(spacing: 8)`), and this rewrite has to be visually equivalent to
    /// it, so the number of points is part of the contract rather than taste.
    static let numberToCodeGap: CGFloat = 8

    /// The document the numbers, tints and stripes come from. Must be the one the
    /// client text view's storage was assembled from, and is swapped together with
    /// it — a stale document here would number rows by the previous diff.
    var document: DiffDocument? {
        didSet {
            // The column's width is a property of the document, so it is refreshed
            // here rather than left to the caller: a two-call protocol would
            // eventually be half-called, and the failure — a gutter that clips
            // five-digit numbers — only shows up on large files.
            reflowWidth()
            needsDisplay = true
        }
    }

    /// Held strongly, and deliberately: the scroll view owns both this ruler and
    /// the text view, and the text view holds no reference back, so there is no
    /// cycle. `clientView` alone would not do — a ruler does not retain it, and it
    /// comes back as an `NSView` needing a downcast on every draw.
    private let textView: DiffTextView

    init(scrollView: NSScrollView, textView: DiffTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        // What makes the ruler's own coordinate system track the client's
        // scrolling, which every conversion below rides on.
        clientView = textView
        // The gutter has no markers and no accessory view. Left at their defaults,
        // AppKit could reserve thickness for both and the drawn column would no
        // longer line up with `ruleThickness`.
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        reflowWidth()
    }

    /// Not failable, unlike `NSView`'s: `NSRulerView` redeclares it that way.
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Sizes the column to the widest line number in the **whole** document.
    ///
    /// One width for every file, not one per file: the ruler is a single column
    /// and the code starts where it ends, so a per-file width would shift the code
    /// sideways at every file boundary. Sizing it from the document also means the
    /// column never has to be measured against the rows currently on screen, which
    /// would make it jump while scrolling.
    ///
    /// With no document there is nothing to size for — `DiffSurfaceView` shows an
    /// empty state instead of the surface — so the column collapses to its stripe
    /// plus the gap.
    func reflowWidth() {
        let widestGutter = document?.files.map(\.gutterWidth).max() ?? 0
        ruleThickness = Self.stripeWidth + widestGutter + codeLeadingGap
    }

    /// The share of `numberToCodeGap` the ruler has to reserve itself, past the
    /// number column and before the code column starts.
    ///
    /// Not the whole gap: the text container already insets its glyphs from its
    /// own leading edge by `lineFragmentPadding` (5 pt by default), that edge is
    /// where the ruler ends, and so that inset falls *inside* the gap. Reserving
    /// the full 8 pt here would put the code a padding's width further right than
    /// the row-based renderer had it — a small drift, but visual equivalence is the one
    /// hard requirement of this rewrite. Read off the container rather than
    /// assumed, so changing the padding keeps the columns where they are.
    private var codeLeadingGap: CGFloat {
        max(Self.numberToCodeGap - (textView.textContainer?.lineFragmentPadding ?? 0), 0)
    }

    /// Draws the gutter's background, then the chrome of every row overlapping
    /// `rect`.
    ///
    /// Nil-tolerant like `DiffTextView.drawBackground(in:)`: with no document, or
    /// on a client migrated to the TextKit 1 stack (no `textLayoutManager`), there
    /// is no geometry to place chrome by, so only the background is painted.
    override func drawHashMarksAndLabels(in rect: NSRect) {
        // The gutter has to read as a continuation of the code column for the row
        // tints to run unbroken beneath it, so it starts from the text view's own
        // background instead of a ruler's default chrome. Painted before the guard
        // below on purpose: a not-yet-configured gutter should look empty rather
        // than show what a ruler would draw by default.
        (textView.drawsBackground ? textView.backgroundColor : .textBackgroundColor).setFill()
        rect.fill()

        guard let document, let layoutManager = textView.textLayoutManager else { return }
        let geometry = DiffFragmentGeometry(layoutManager: layoutManager, document: document)

        for row in geometry.fragments(in: containerRect(from: rect)) {
            let line = document.lines[row.lineIndex]
            // Hunk headers and notes are chrome: no tint, no stripe, no number —
            // they had none in the row-based renderer either.
            guard let kind = line.diffKind else { continue }
            let band = rulerBand(ofRow: row.rect)

            if let tint = DiffTextView.rowTint(for: kind) {
                tint.setFill()
                band.fill()
            }
            if let stripe = Self.stripeColor(for: kind) {
                stripe.setFill()
                NSRect(x: band.minX, y: band.minY, width: Self.stripeWidth, height: band.height).fill()
            }
            // A wrapped line covers several rows but is one line, so its number is
            // printed once, on the row that starts it.
            if row.isLineStart, let number = line.number {
                draw(number: number, in: band, kind: kind)
            }
        }
    }

    /// Ruler coordinates → the text-container coordinates
    /// `DiffFragmentGeometry` answers in.
    ///
    /// Two shifts, and both matter: `convert(_:to:)` takes out the scroll offset
    /// (the ruler's and the clip view's, and any difference in flippedness between
    /// the two views), and `textContainerOrigin` takes out the reserved header band
    /// the text view holds above its container. The origin rather than
    /// `textContainerInset`: it is the API that reports where the container sits,
    /// inset plus any centering AppKit applies.
    private func containerRect(from rulerRect: NSRect) -> NSRect {
        convert(rulerRect, to: textView).offsetBy(dx: 0, dy: -textView.textContainerOrigin.y)
    }

    /// A row's band in ruler coordinates: the row's vertical extent, the ruler's
    /// full width.
    ///
    /// The row's own horizontal extent is discarded — it is where the *glyphs* are,
    /// in the *text view*, and neither answers where the gutter's chrome goes. It
    /// is still fed through the conversion as part of the rect, because converting
    /// a rect is what keeps the arithmetic right if the two views disagree about
    /// flippedness; converting the top edge as a point would not.
    private func rulerBand(ofRow row: NSRect) -> NSRect {
        let inView = row.offsetBy(dx: 0, dy: textView.textContainerOrigin.y)
        let inRuler = convert(inView, from: textView)
        return NSRect(x: bounds.minX, y: inRuler.minY, width: bounds.width, height: inRuler.height)
    }

    /// Draws one line number right-aligned in its row's band, clear of the stripe
    /// on the leading side and of the code column on the trailing side.
    ///
    /// The column is the band minus the stripe and the gap, which by
    /// `reflowWidth()`'s arithmetic leaves exactly the document's widest
    /// `FileSpan.gutterWidth`, at exactly the offset `DiffLineRow` put it: no digit
    /// can clip, and the column has not moved.
    ///
    /// Aligned to the top of the band rather than to the code's baseline: the two
    /// faces differ in size, so matching baselines would take ascent arithmetic
    /// that the row-based renderer's `HStack(alignment: .top)` did not do either.
    private func draw(number: Int, in band: NSRect, kind: GitDiffLine.Kind) {
        let column = NSRect(
            x: band.minX + Self.stripeWidth, y: band.minY,
            width: max(band.width - Self.stripeWidth - codeLeadingGap, 0),
            height: band.height)
        (String(number) as NSString).draw(in: column, withAttributes: Self.numberAttributes(for: kind))
    }

    /// The attributes one row's number is drawn with: context rows keep the
    /// neutral gray, changed rows pick up the same accent as their stripe —
    /// `DiffLineRow.numberColor`'s rule, unchanged.
    ///
    /// Three prebuilt dictionaries instead of one composed per row. This runs for
    /// every numbered row on screen on every scroll frame, and the only thing that
    /// varies between rows is the color, of which there are exactly three.
    private static func numberAttributes(for kind: GitDiffLine.Kind) -> [NSAttributedString.Key: Any] {
        switch kind {
        case .addition: additionNumberAttributes
        case .deletion: deletionNumberAttributes
        case .context: contextNumberAttributes
        }
    }

    private static let additionNumberAttributes = makeNumberAttributes(color: additionAccent)
    private static let deletionNumberAttributes = makeNumberAttributes(color: deletionAccent)
    private static let contextNumberAttributes = makeNumberAttributes(color: contextNumberColor)

    private static func makeNumberAttributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: numberFont, .foregroundColor: color, .paragraphStyle: rightAligned]
    }

    /// The line numbers' face, monospaced so the digits of successive rows line up
    /// into a column.
    ///
    /// The diff draws text at three sizes and each one is deliberate: 14 pt for
    /// code (`DiffTextAssembly.codeFont`), 10 pt for the chrome lines that are
    /// commentary rather than code (`DiffTextAssembly.chromeFontSize`), and 12 pt
    /// here. A number is a reference mark beside the code — quieter than the code,
    /// but not as quiet as a hunk header, which it would be at 10. 12 pt is also
    /// what the row-based renderer's gutter used, and this rewrite has to be
    /// visually equivalent to it.
    private static let numberFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    /// A number never wraps: the column is sized for the widest one in the
    /// document, and a second row of digits would spill into the next line's band.
    /// Immutable (`copy()`) because it is shared by every row of every document.
    private static let rightAligned: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        style.lineBreakMode = .byClipping
        return style.copy() as! NSParagraphStyle
    }()

    /// The accent stripe's color, or `nil` for a context row — whose
    /// `DiffLineStyle.accent(for:)` is `Color.clear`, so there is nothing to paint.
    private static func stripeColor(for kind: GitDiffLine.Kind) -> NSColor? {
        switch kind {
        case .addition: additionAccent
        case .deletion: deletionAccent
        case .context: nil
        }
    }

    /// Converted once, not once per row per frame: `NSColor(_:)` allocates a
    /// dynamic catalog color each time.
    private static let additionAccent = NSColor(DiffLineStyle.accent(for: .addition))
    private static let deletionAccent = NSColor(DiffLineStyle.accent(for: .deletion))
    private static let contextNumberColor = NSColor(DiffLineStyle.contextNumberTint)
}
