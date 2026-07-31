import CasperGit
import Foundation

/// The whole diff flattened into one text document plus the spans that map it
/// back to the diff model: one paragraph per rendered line, each terminated by
/// `"\n"`.
///
/// This is a pure value built off the main actor. Everything the renderer draws
/// — row tints, gutter numbers, the sticky file header — is a span recorded
/// here, so the diff view's semantics (numbering, truncation, line budgets) can
/// be pinned down by unit tests instead of by looking at a screen.
///
/// Offsets are UTF-16 units, because `NSRange` and `NSTextStorage` are.
///
/// Two invariants the renderer relies on:
///
/// - **One `LineSpan` is exactly one TextKit paragraph.** Anything TextKit
///   would treat as a paragraph separator is flattened to a space, so a line
///   never splits into several layout fragments (see
///   `flatteningSeparators(_:)`).
/// - **Every `FileSpan` owns at least one paragraph**, so its `range.length` is
///   always greater than zero and its start offset is distinct from the next
///   file's. A file with nothing to show gets a `.note` line instead — without
///   that, two files would share a start offset and the geometry could not tell
///   them apart.
struct DiffDocument: Sendable, Equatable {
    /// One file's contribution to the document: what its header bar shows, and
    /// which slice of `text` / `lines` belongs to it.
    struct FileSpan: Sendable, Equatable {
        /// `GitDiffFile.id` — stable across successive diff computations, which
        /// is what scroll anchoring and progressive highlighting key on.
        let id: String
        let title: String
        let status: String
        let insertions: Int
        let deletions: Int
        let gutterWidth: CGFloat
        /// Covers the file's paragraphs including their terminators.
        let range: NSRange
        let firstLineIndex: Int
        let lineCount: Int
    }

    /// One rendered paragraph.
    struct LineSpan: Sendable, Equatable {
        enum Kind: String, Sendable {
            case context, addition, deletion, hunkHeader, note

            init(_ diffKind: GitDiffLine.Kind) {
                switch diffKind {
                case .context: self = .context
                case .addition: self = .addition
                case .deletion: self = .deletion
                }
            }
        }

        let kind: Kind
        /// The single gutter line number, per `DiffLineStyle.lineNumber(for:)`;
        /// `nil` for hunk headers and notes. Also the 1-based index a syntax
        /// highlight is looked up by.
        let number: Int?
        /// The paragraph's text, without its trailing `"\n"`.
        let range: NSRange
        /// The source line's own text: `range` minus the leading `+`/`-`/space
        /// cue and minus the truncation marker. A syntax highlight may only
        /// ever be applied here.
        let contentRange: NSRange
        let fileIndex: Int
        let truncated: Bool

        /// The diff kind this line renders, or `nil` for the chrome lines
        /// (hunk headers and notes) that have no counterpart in the diff.
        var diffKind: GitDiffLine.Kind? {
            switch kind {
            case .context: .context
            case .addition: .addition
            case .deletion: .deletion
            case .hunkHeader, .note: nil
            }
        }
    }

    /// Per-file cap on emitted diff lines, so one generated lockfile cannot
    /// starve every other file in the document.
    static let maxLinesPerFile = 3000

    /// Document-wide cap on emitted diff lines. Display cost no longer scales
    /// with document length (TextKit lays out only the viewport), but building
    /// this value and its attribute runs still does, so a many-file diff needs
    /// a bound of its own on top of the per-file one.
    static let maxTotalLines = 20_000

    /// Appended after a truncated line's content, outside `contentRange`.
    static let truncationMarker = "  … (line truncated)"

    let text: String
    let files: [FileSpan]
    let lines: [LineSpan]
    /// Diff lines dropped by either budget, across the whole document.
    let hiddenLineCount: Int

    init(diff: GitDiff) {
        var text = ""
        // Tracked as the text grows: ranges must be recorded at append time —
        // searching the finished string for a span would be both quadratic and
        // ambiguous — and asking a Swift String for its UTF-16 length is O(n).
        var offset = 0
        var files: [FileSpan] = []
        var lines: [LineSpan] = []
        var hiddenLineCount = 0
        var remainingTotal = Self.maxTotalLines

        /// Appends one paragraph and records its span. `prefixLength` and
        /// `suffixLength` are the UTF-16 lengths carved out of `body` that
        /// `contentRange` must exclude.
        func append(
            _ body: String, kind: LineSpan.Kind, number: Int? = nil, fileIndex: Int,
            prefixLength: Int = 0, suffixLength: Int = 0, truncated: Bool = false
        ) {
            let paragraph = Self.flatteningSeparators(body)
            let length = paragraph.utf16.count
            text += paragraph
            text += "\n"
            lines.append(LineSpan(
                kind: kind, number: number,
                range: NSRange(location: offset, length: length),
                contentRange: NSRange(
                    location: offset + prefixLength,
                    length: length - prefixLength - suffixLength),
                fileIndex: fileIndex, truncated: truncated))
            offset += length + 1  // + the paragraph terminator
        }

        for (fileIndex, file) in diff.files.enumerated() {
            let fileStart = offset
            let firstLineIndex = lines.count
            var hiddenInFile = 0
            var remainingInFile = Self.maxLinesPerFile

            if file.isBinary {
                append("Binary file", kind: .note, fileIndex: fileIndex)
            } else {
                for hunk in file.hunks {
                    let allowance = min(remainingInFile, remainingTotal)
                    // A hunk with no budget left is dropped whole, header
                    // included: a header on its own would announce lines that
                    // never come.
                    guard allowance > 0 else {
                        hiddenInFile += hunk.lines.count
                        continue
                    }
                    append(hunk.header, kind: .hunkHeader, fileIndex: fileIndex)
                    let emitted = min(hunk.lines.count, allowance)
                    for line in hunk.lines.prefix(emitted) {
                        // `truncatedForDisplay` caps by grapheme cluster while
                        // `contentRange.length` counts UTF-16 units, so the two
                        // numbers only coincide for ASCII: a capped line of
                        // emoji has `maxDisplayLineLength` clusters and a longer
                        // range. Nothing here requires them to be equal.
                        let display = DiffLineStyle.truncatedForDisplay(line.content)
                        let prefix = DiffLineStyle.prefix(for: line.kind)
                        let marker = display.truncated ? Self.truncationMarker : ""
                        append(
                            prefix + display.text + marker,
                            kind: LineSpan.Kind(line.kind),
                            number: DiffLineStyle.lineNumber(for: line), fileIndex: fileIndex,
                            prefixLength: prefix.utf16.count,
                            suffixLength: marker.utf16.count, truncated: display.truncated)
                    }
                    hiddenInFile += hunk.lines.count - emitted
                    remainingInFile -= emitted
                    remainingTotal -= emitted
                }
                if hiddenInFile > 0 {
                    // Also the only line a file that got no budget at all
                    // contributes, so it never renders as an empty file.
                    append(
                        "Diff too large — \(hiddenInFile) more lines hidden",
                        kind: .note, fileIndex: fileIndex)
                } else if lines.count == firstLineIndex {
                    // A non-binary file with no hunks: a mode-only change
                    // (`chmod +x`) or a typechange. It gets a note so the file
                    // still owns a paragraph — see the invariants above.
                    append("No content changes", kind: .note, fileIndex: fileIndex)
                }
            }

            let metrics = Self.metrics(of: file)
            files.append(FileSpan(
                id: file.id, title: Self.title(of: file), status: file.status.rawValue,
                insertions: metrics.insertions, deletions: metrics.deletions,
                gutterWidth: metrics.gutterWidth,
                range: NSRange(location: fileStart, length: offset - fileStart),
                firstLineIndex: firstLineIndex, lineCount: lines.count - firstLineIndex))
            hiddenLineCount += hiddenInFile
        }

        self.text = text
        self.files = files
        self.lines = lines
        self.hiddenLineCount = hiddenLineCount
    }

    /// The line whose paragraph contains `offset`, or `nil` past the end of the
    /// document. Paragraphs tile `text` with no gaps, so a binary search over
    /// the ascending line starts answers this; the renderer asks once per
    /// visible text fragment, which is why it is not a linear scan.
    func lineIndex(atCharacterOffset offset: Int) -> Int? {
        // The last paragraph's terminator sits at `NSMaxRange(range)`, so that
        // offset still belongs to the document; one past it does not.
        guard let last = lines.last, offset >= 0, offset <= NSMaxRange(last.range) else { return nil }
        var low = 0
        var high = lines.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lines[middle].range.location <= offset {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return low
    }

    /// A linear scan on purpose: a diff has tens of files, not thousands.
    func fileIndex(withID id: String) -> Int? {
        files.firstIndex { $0.id == id }
    }

    /// `selection` split into the pieces that are actually the reader's text: the
    /// same characters minus every line's leading `+`/`-`/space cue.
    ///
    /// The cue is rendering, not source. So it is carved out of the selection even
    /// though it is carved *in* to the text — a highlight running through it would
    /// invite a copy that no longer compiles, and the alternative of keeping the
    /// cue out of the storage entirely and drawing it like the gutter numbers
    /// would also take it out of TextKit's character-accurate layout of the code
    /// column.
    ///
    /// This is the one definition of "the cue is not part of the text", used both
    /// for what `DiffTextView` lets the reader select and for what it puts on the
    /// pasteboard. Those cannot disagree because there is nothing to disagree
    /// with: applying it to an already-carved selection changes nothing.
    ///
    /// Everything else survives verbatim, terminators included, so a multi-line
    /// selection keeps its line structure. In particular a truncated line's
    /// `… (line truncated)` marker stays: it is the only signal that the text is a
    /// prefix of the real line, and dropping it would hand the reader a silently
    /// corrupt paste.
    ///
    /// Chrome lines have no cue — their `contentRange` starts where their `range`
    /// does — so hunk headers and notes come through whole without a special case.
    /// Returns an empty array for an empty selection, and for one that covers
    /// nothing but cues.
    func rangesExcludingCues(in selection: NSRange) -> [NSRange] {
        let end = NSMaxRange(selection)
        guard selection.length > 0 else { return [] }
        // Past the end of the document there is no line to read a cue from, and
        // nothing sensible to carve: hand the selection back untouched.
        guard let firstLine = lineIndex(atCharacterOffset: selection.location) else { return [selection] }

        var kept: [NSRange] = []
        // The start of the next piece: everything from here to the next cue is
        // copied. Advances past each cue instead of over it.
        var cursor = selection.location

        for line in lines[firstLine...] {
            // Lines are ordered, so the first one starting at or after the
            // selection's end ends the walk.
            guard line.range.location < end else { break }
            let cueStart = line.range.location
            let cueEnd = line.contentRange.location
            // No cue at all, or one the cursor has already passed — which is how
            // a selection starting mid-line skips its own line's cue.
            guard cueEnd > cueStart, cueEnd > cursor else { continue }

            let clipped = max(cueStart, cursor)
            if clipped > cursor {
                kept.append(NSRange(location: cursor, length: clipped - cursor))
            }
            // Clamped to the selection, so a selection ending inside a cue does
            // not reach past it.
            cursor = min(cueEnd, end)
        }
        if cursor < end {
            kept.append(NSRange(location: cursor, length: end - cursor))
        }
        return kept
    }

    /// Every scalar TextKit starts a new paragraph on.
    private static let paragraphSeparators: Set<Unicode.Scalar> = [
        "\u{000A}",  // LINE FEED
        "\u{000B}",  // LINE TABULATION
        "\u{000C}",  // FORM FEED
        "\u{000D}",  // CARRIAGE RETURN
        "\u{0085}",  // NEXT LINE
        "\u{2028}",  // LINE SEPARATOR
        "\u{2029}",  // PARAGRAPH SEPARATOR
    ]

    /// Replaces every paragraph separator inside a line's text with a space, so
    /// that one `LineSpan` really is one TextKit paragraph.
    ///
    /// `Repository.mapLine` strips only a *trailing* LF or CRLF: a lone trailing
    /// `\r`, and any separator inside the content, reach us untouched — a
    /// CR-only-terminated file arrives from libgit2 as a single "line" full of
    /// `\r`. TextKit would lay such a line out as several fragments, which would
    /// print its gutter number once per fragment and tint full-width rows that
    /// carry no `+`/`-` cue.
    ///
    /// The substitution is deliberately 1:1 and length-preserving — each of
    /// those scalars is a single UTF-16 code unit, and so is a space. Two things
    /// depend on that: the caller's `prefixLength`/`suffixLength` arithmetic
    /// stays valid without recomputation, and `DiffTextAssembly`'s highlight
    /// guard (highlighted length must equal `contentRange.length`) keeps
    /// matching, so an affected line still gets its syntax colors instead of
    /// silently falling back to neutral. Dropping the separators, or swapping in
    /// a visible glyph, would break both.
    private static func flatteningSeparators(_ body: String) -> String {
        guard body.unicodeScalars.contains(where: paragraphSeparators.contains) else { return body }
        // Scalar by scalar, never `Character` by `Character`: a CRLF pair is one
        // grapheme cluster but two code units, and collapsing it to one space
        // would shorten the line.
        var flattened = String.UnicodeScalarView()
        flattened.reserveCapacity(body.unicodeScalars.count)
        for scalar in body.unicodeScalars {
            flattened.append(paragraphSeparators.contains(scalar) ? " " : scalar)
        }
        return String(flattened)
    }

    /// Header stats and gutter width, computed over **all** of a file's lines
    /// including any the budgets hide: the header describes the change, not what
    /// got rendered. Same arithmetic as the previous row-based renderer, so the
    /// gutter keeps its width.
    private static func metrics(
        of file: GitDiffFile
    ) -> (insertions: Int, deletions: Int, gutterWidth: CGFloat) {
        var insertions = 0
        var deletions = 0
        var widestLineNumber = 0
        for hunk in file.hunks {
            for line in hunk.lines {
                switch line.kind {
                case .addition: insertions += 1
                case .deletion: deletions += 1
                case .context: break
                }
                if let old = line.oldLineNumber { widestLineNumber = max(widestLineNumber, old) }
                if let new = line.newLineNumber { widestLineNumber = max(widestLineNumber, new) }
            }
        }
        // The widest number sets the width so the column never truncates (e.g.
        // 5-digit numbers in a large file): one number plus trailing padding,
        // with a floor so short files don't get a cramped column.
        let maxDigits = max(String(widestLineNumber).count, 1)
        return (insertions, deletions, max(CGFloat(maxDigits * 9 + 12), 36))
    }

    /// The path as the header bar shows it: both sides joined for a rename,
    /// otherwise whichever side exists (a deletion has no new path).
    private static func title(of file: GitDiffFile) -> String {
        if file.oldPath.isEmpty { return file.newPath }
        if file.newPath.isEmpty { return file.oldPath }
        return file.oldPath == file.newPath ? file.newPath : "\(file.oldPath) → \(file.newPath)"
    }
}
