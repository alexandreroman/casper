import AppKit
import CasperGit
import SwiftUI

/// Syntax-highlighted lines for one diff file, indexed by 1-based source line
/// number. `new` covers the working-tree side (additions and context lines),
/// `old` the HEAD side (deletions); either is `nil` when that side could not be
/// highlighted (unknown language, oversized file, highlighter failure).
struct DiffFileHighlight: Sendable {
    let new: [AttributedString]?
    let old: [AttributedString]?
}

/// Turns a `DiffDocument` into an `NSTextStorage`, and paints syntax-highlight
/// colors onto an already-assembled one.
///
/// This is the only writer of text attributes in the diff renderer, which is
/// what makes the color-only rule enforceable: `applyHighlight` sets nothing but
/// `.foregroundColor`, so a highlight landing while the reader scrolls can never
/// change a line height and shift the text under them.
///
/// `@MainActor` for two reasons. The `NSFont` and `NSParagraphStyle` statics
/// below are not `Sendable`, so they need an actor to live on — the `NSColor`
/// ones would not, `NSColor` being `Sendable`. And the `NSTextStorage` these
/// functions mutate is read by a text view on the main thread, so the isolation
/// is what statically stops a later caller from writing to it off-main.
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

    /// Builds the storage: one document-wide pass for the attributes almost every
    /// paragraph shares, then the handful of overrides.
    ///
    /// The text itself comes verbatim from `document.text`, so every offset the
    /// renderer holds keeps pointing at the same characters.
    static func makeTextStorage(for document: DiffDocument) -> NSTextStorage {
        let storage = NSTextStorage(string: document.text)
        storage.beginEditing()
        storage.setAttributes(codeAttributes, range: NSRange(location: 0, length: storage.length))

        for (fileIndex, file) in document.files.enumerated() {
            let fileLines = lines(of: file, in: document)

            // Only files after the first reserve their band this way: TextKit
            // ignores `paragraphSpacingBefore` on the document's very first
            // paragraph, so the first file's band comes from the text view's
            // `textContainerInset` instead.
            if fileIndex > 0, let first = fileLines.first {
                storage.addAttribute(
                    .paragraphStyle, value: laterFileStyle, range: paragraphRange(of: first))
            }

            for line in fileLines {
                guard let kind = line.diffKind else {
                    // A hunk header or a note: chrome, in the smaller face and
                    // the dimmer color.
                    storage.addAttributes(chromeAttributes(for: line.kind), range: paragraphRange(of: line))
                    continue
                }

                if let accent = accentColor(for: kind) {
                    // The `+`/`-` cue is tinted like the stripe and the gutter
                    // number, and sits outside `contentRange` so a syntax highlight
                    // never overwrites it.
                    storage.addAttribute(
                        .foregroundColor, value: accent,
                        range: NSRange(
                            location: line.range.location,
                            length: line.contentRange.location - line.range.location))
                }

                if line.truncated {
                    // The `… (line truncated)` marker is our own commentary, not
                    // part of the source line: it reads as chrome.
                    let markerStart = NSMaxRange(line.contentRange)
                    storage.addAttribute(
                        .foregroundColor, value: NSColor.secondaryLabelColor,
                        range: NSRange(location: markerStart, length: NSMaxRange(line.range) - markerStart))
                }
            }
        }
        storage.endEditing()
        return storage
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
        _ highlight: DiffFileHighlight, forFileAt fileIndex: Int, in storage: NSTextStorage,
        document: DiffDocument
    ) {
        guard document.files.indices.contains(fileIndex) else { return }
        let file = document.files[fileIndex]
        // A storage assembled from a different document has unrelated offsets,
        // so this document's ranges would recolor arbitrary text — or raise an
        // out-of-bounds exception. Refuse rather than guess.
        guard storage.length == (document.text as NSString).length else { return }

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

    /// The chrome lines' overrides — face and color only, so whatever paragraph
    /// style the line already carries survives.
    private static func chromeAttributes(
        for kind: DiffDocument.LineSpan.Kind
    ) -> [NSAttributedString.Key: Any] {
        [
            .font: kind == .hunkHeader ? hunkHeaderFont : noteFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
    }

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

    /// `NSColor(_:)` wraps a SwiftUI `Color` in a freshly allocated dynamic
    /// catalog color, so the accents are converted once instead of per line.
    private static let insertionAccent = NSColor(DiffLineStyle.insertionTint)
    private static let deletionAccent = NSColor(DiffLineStyle.deletionTint)

    /// The accent for a line's `+`/`-` cue, or `nil` for a context line — whose
    /// prefix is a space and whose accent is `Color.clear`, so there is nothing
    /// to paint.
    private static func accentColor(for kind: GitDiffLine.Kind) -> NSColor? {
        switch kind {
        case .addition: insertionAccent
        case .deletion: deletionAccent
        case .context: nil
        }
    }

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
