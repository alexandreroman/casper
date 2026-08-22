import AppKit
import CasperGit
import SwiftUI

/// Syntax-highlighted lines for one diff file, indexed by 1-based source line
/// number. `new` covers the working-tree side (additions and context lines),
/// `old` the HEAD side (deletions); either is `nil` when that side could not be
/// highlighted (unknown language, oversized file, highlighter failure).
///
/// An entry may also be a deliberately empty `AttributedString`, standing for a
/// line the document does not render — see `prunedToRenderedLines(ofFileAt:in:)`.
struct DiffFileHighlight: Sendable {
    let new: [AttributedString]?
    let old: [AttributedString]?

    /// The same highlight with every line the document does not render blanked
    /// out, keeping the surviving lines at the very indices `DiffTextAssembly`
    /// looks them up by.
    ///
    /// The highlighter colors a whole file — up to `maxHighlightBytes`, so some
    /// 15 000 lines per side — while a diff of that file usually renders a few
    /// dozen of them. Everything else is text and attribute runs the cache would
    /// hold for the diff's whole lifetime and nothing would ever read, which
    /// makes this the renderer's largest avoidable allocation.
    ///
    /// A blanked line is an empty `AttributedString` rather than a hole, so the
    /// array stays indexable by line number; painting one is a no-op, since its
    /// length cannot match the line's.
    ///
    /// Pruning is against *this* document, and a carried highlight is never
    /// recomputed — so a later document that renders more of the same
    /// unchanged file (the shared `maxTotalLines` budget having freed up above
    /// it) leaves those extra lines neutral until the file itself changes. That
    /// only reaches lines a truncation note already warns the reader about.
    func prunedToRenderedLines(ofFileAt fileIndex: Int, in document: DiffDocument) -> DiffFileHighlight {
        guard document.files.indices.contains(fileIndex) else { return self }
        let rendered = document.renderedLineNumbers(ofFileAt: fileIndex)
        return DiffFileHighlight(
            new: Self.keeping(rendered.new, of: new), old: Self.keeping(rendered.old, of: old))
    }

    /// `lines` with everything outside `numbers` (1-based) blanked, truncated
    /// past the last number that survives.
    private static func keeping(_ numbers: Set<Int>, of lines: [AttributedString]?) -> [AttributedString]? {
        guard let lines else { return nil }
        guard let highest = numbers.max() else { return [] }
        let kept = min(highest, lines.count)
        return (0..<kept).map { numbers.contains($0 + 1) ? lines[$0] : AttributedString() }
    }
}

/// Turns a `DiffDocument` into the attributed text a text storage is filled
/// from, and paints syntax-highlight colors onto an already-assembled one.
///
/// This is the only writer of text attributes in the diff renderer, which is
/// what makes the color-only rule enforceable: `applyHighlight` sets nothing but
/// `.foregroundColor`, so a highlight landing while the reader scrolls can never
/// change a line height and shift the text under them.
///
/// `@MainActor` for two reasons. The `NSFont` and `NSParagraphStyle` statics
/// below are not `Sendable`, so they need an actor to live on — the `NSColor`
/// ones would not, `NSColor` being `Sendable`. And the text storage
/// `applyHighlight` mutates is read by a text view on the main thread, so the
/// isolation is what statically stops a later caller from writing to it
/// off-main.
@MainActor
enum DiffTextAssembly {
    /// The code column's font. Line numbers live in the ruler, so the whole
    /// document is one uniform monospaced size.
    static let codeFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)

    /// Point size of the chrome lines — hunk headers and notes — which are
    /// commentary rather than code.
    ///
    /// This mirrors SwiftUI's `.caption`, which the row-based renderer styled
    /// both with and which resolves to 10 pt on macOS. The rewrite has to be
    /// visually equivalent, so the size is pinned to that rather than rounded up.
    static let chromeFontSize: CGFloat = 10

    /// Hunk headers, monospaced: `@@ -1,4 +1,6 @@` is positional, and it keeps
    /// the code column's rhythm.
    static let hunkHeaderFont = NSFont.monospacedSystemFont(ofSize: chromeFontSize, weight: .regular)

    /// The `Binary file` / `Diff too large` notes, in the proportional system
    /// face: they are prose, not code. Attributes are per-paragraph, so the notes
    /// and the hunk headers can differ even though both are chrome.
    static let noteFont = NSFont.systemFont(ofSize: chromeFontSize)

    /// Height of one sticky file-header bar. Doubles as the height of the blank
    /// band reserved ahead of each file, since the bar is drawn by an overlay
    /// that must not cover the file's first line.
    static let headerBandHeight: CGFloat = 31

    /// Breathing room between two files, on top of the reserved header band —
    /// the same 14 pt the row-based renderer put after every file but the last.
    static let interFileGap: CGFloat = 14

    /// Builds the document's attributed text: one document-wide pass for the
    /// attributes almost every paragraph shares, then the handful of overrides.
    ///
    /// The text itself comes verbatim from `document.text`, so every offset the
    /// renderer holds keeps pointing at the same characters.
    ///
    /// A plain `NSMutableAttributedString` rather than an `NSTextStorage`: this
    /// value only ever feeds `setAttributedString`, which copies it into the live
    /// storage, and a storage of its own would have made that a second full copy
    /// of the text and of every attribute run — up to 20 000 paragraphs, on the
    /// main actor, on a path an FSEvents watcher drives.
    static func makeAttributedText(for document: DiffDocument) -> NSMutableAttributedString {
        let attributed = NSMutableAttributedString(string: document.text)
        attributed.setAttributes(codeAttributes, range: NSRange(location: 0, length: attributed.length))

        for (fileIndex, file) in document.files.enumerated() {
            let fileLines = lines(of: file, in: document)

            // Only files after the first reserve their band this way: TextKit
            // ignores `paragraphSpacingBefore` on the document's very first
            // paragraph, so the first file's band comes from the text view's
            // `textContainerInset` instead.
            if fileIndex > 0, let first = fileLines.first {
                attributed.addAttribute(
                    .paragraphStyle, value: laterFileStyle, range: paragraphRange(of: first))
            }

            for line in fileLines {
                guard line.diffKind != nil else {
                    // A hunk header or a note: chrome, in the smaller face and
                    // the dimmer color.
                    let chrome = line.kind == .hunkHeader ? hunkHeaderAttributes : noteAttributes
                    attributed.addAttributes(chrome, range: paragraphRange(of: line))
                    continue
                }

                // The `… (line truncated)` marker is our own commentary, not part
                // of the source line: it reads as chrome. A code line carries no
                // other override — its `+`/`-` cue is the gutter's business.
                guard line.truncated else { continue }
                let markerStart = NSMaxRange(line.contentRange)
                attributed.addAttribute(
                    .foregroundColor, value: NSColor.secondaryLabelColor,
                    range: NSRange(location: markerStart, length: NSMaxRange(line.range) - markerStart))
            }
        }
        return attributed
    }

    /// Paints many files' syntax colors onto `storage` in a single edit
    /// transaction, in the order given — which must be ascending, see
    /// `DiffRendering.highlightsInDocumentOrder`.
    ///
    /// One transaction for the batch rather than one per file: `endEditing()`
    /// invalidates the text view's layout, and a whole-document repaint after a
    /// storage swap carries one highlight per file, so a 60-file diff would
    /// otherwise cost 60 layout cycles for a single refresh. The transactions
    /// nest, so `applyHighlight`'s own pair below stays where it is and is what
    /// keeps a lone progressive highlight correct.
    static func applyHighlights(
        _ highlights: [(fileIndex: Int, highlight: DiffFileHighlight)],
        in storage: NSMutableAttributedString, document: DiffDocument
    ) {
        storage.beginEditing()
        defer { storage.endEditing() }
        for (fileIndex, highlight) in highlights {
            applyHighlight(highlight, forFileAt: fileIndex, in: storage, document: document)
        }
    }

    /// Paints one file's syntax colors onto `storage`, which must have been
    /// assembled from `document`.
    ///
    /// Called once per file as the highlighter finishes it, so this runs while
    /// the reader is already scrolling the document. Hence the two rules: only
    /// `.foregroundColor` is written, and a line whose highlight does not line up
    /// exactly with its `contentRange` is left in the neutral base color —
    /// misaligned colors are worse than none.
    ///
    /// Idempotent: each code line is reset to the base color before its runs go
    /// on, so re-highlighting a file cannot leave an earlier pass's colors on a
    /// line this pass skips, and the promise above holds unconditionally.
    static func applyHighlight(
        _ highlight: DiffFileHighlight, forFileAt fileIndex: Int, in storage: NSMutableAttributedString,
        document: DiffDocument
    ) {
        guard document.files.indices.contains(fileIndex) else { return }
        let file = document.files[fileIndex]
        // A storage assembled from a different document has unrelated offsets,
        // so this document's ranges would recolor arbitrary text — or raise an
        // out-of-bounds exception. Refuse rather than guess.
        guard storage.length == document.textLength else { return }

        storage.beginEditing()
        defer { storage.endEditing() }

        for line in lines(of: file, in: document) {
            // Chrome lines (hunk headers, notes) have no source line to color.
            guard let kind = line.diffKind else { continue }
            storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: line.contentRange)

            // A truncated line's content is a prefix of the source line, so a
            // full-line highlight would spill past where the text stops.
            guard !line.truncated, let number = line.number else { continue }
            let side = kind == .deletion ? highlight.old : highlight.new
            guard let side, side.indices.contains(number - 1) else { continue }
            let highlighted = side[number - 1]
            // A length disagreement means the highlighted file text and the diff
            // line drifted apart (line-ending normalisation, a concurrent edit).
            guard utf16Length(highlighted.unicodeScalars) == line.contentRange.length else { continue }

            var offset = line.contentRange.location
            for run in highlighted.runs {
                let length = utf16Length(highlighted[run.range].unicodeScalars)
                defer { offset += length }
                guard let color = foregroundColor(in: run.attributes) else { continue }
                storage.addAttribute(
                    .foregroundColor, value: color,
                    range: NSRange(location: offset, length: length))
            }
        }
    }

    /// A highlight run's color, and nothing else it carries — a font above all is
    /// deliberately dropped.
    ///
    /// The **AppKit** scope is where the color actually is: `DiffHighlighter`'s
    /// producer, HighlightSwift, ends its conversion with
    /// `AttributedString(_:including: \.appKit)`, so a run's color is an `NSColor`
    /// there and `run.attributes.swiftUI.foregroundColor` is `nil` for every run
    /// of every highlighted line. Reading only the SwiftUI scope applies no color
    /// at all, and does so silently — every range check still agrees, so the diff
    /// renders exactly as it would for an unknown language. The SwiftUI read stays
    /// as a fallback so either producer works, with AppKit taking precedence.
    private static func foregroundColor(in attributes: AttributeContainer) -> NSColor? {
        if let appKitColor = attributes.appKit.foregroundColor {
            return appKitColor
        }
        if let swiftUIColor = attributes.swiftUI.foregroundColor {
            return NSColor(swiftUIColor)
        }
        return nil
    }

    /// What every paragraph starts from, set over the whole document in a single
    /// call. Only four attribute combinations exist (chrome or code, band or no
    /// band), so building one dictionary per paragraph would cost a 20 000-line
    /// diff 20 000 allocations for four distinct values.
    private static let codeAttributes: [NSAttributedString.Key: Any] = [
        .font: codeFont,
        .foregroundColor: NSColor.labelColor,
        .paragraphStyle: wrappingStyle,
    ]

    /// A hunk header's overrides — face and color only, so whatever paragraph
    /// style the line already carries survives. Prebuilt for the same reason
    /// `codeAttributes` is: every hunk of every file would otherwise allocate its
    /// own copy of one of these two values.
    private static let hunkHeaderAttributes: [NSAttributedString.Key: Any] = [
        .font: hunkHeaderFont,
        .foregroundColor: NSColor.secondaryLabelColor,
    ]

    /// A note's overrides, in the proportional face the notes are set in.
    private static let noteAttributes: [NSAttributedString.Key: Any] = [
        .font: noteFont,
        .foregroundColor: NSColor.secondaryLabelColor,
    ]

    /// The base paragraph style, built once.
    ///
    /// `copy()` is what makes it genuinely immutable: `NSAttributedString` stores
    /// a paragraph style by reference, not by value, so without the copy a single
    /// `as? NSMutableParagraphStyle` downcast downstream would reflow every
    /// paragraph of every document at once.
    private static let wrappingStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        return style.copy() as! NSParagraphStyle
    }()

    /// `wrappingStyle` plus the blank band a later file's sticky header draws
    /// into. Reserved as spacing rather than as characters, so selection and copy
    /// yield no stray empty lines.
    private static let laterFileStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.paragraphSpacingBefore = headerBandHeight + interFileGap
        return style.copy() as! NSParagraphStyle
    }()

    /// The line spans belonging to one file.
    private static func lines(
        of file: DiffDocument.FileSpan, in document: DiffDocument
    ) -> ArraySlice<DiffDocument.LineSpan> {
        document.lines[file.firstLineIndex..<(file.firstLineIndex + file.lineCount)]
    }

    /// A line's span extended over its `"\n"`. The terminator belongs to the
    /// paragraph it ends, and leaving it with different attributes would let
    /// another font size the paragraph's last line fragment.
    private static func paragraphRange(of line: DiffDocument.LineSpan) -> NSRange {
        NSRange(location: line.range.location, length: line.range.length + 1)
    }

    /// UTF-16 length — the unit `NSRange` and `NSTextStorage` count in — of a
    /// scalar sequence.
    ///
    /// Measured scalar by scalar rather than through a materialised `String`, so
    /// a run boundary that falls inside a grapheme cluster cannot round the count
    /// outwards and desynchronise the following runs.
    /// (`AttributedString.utf16` would answer this directly but is macOS 26+.)
    private static func utf16Length(_ scalars: some Sequence<Unicode.Scalar>) -> Int {
        scalars.reduce(0) { $0 + UTF16.width($1) }
    }
}
