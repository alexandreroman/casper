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
        /// Carried as the status itself, not as its word: the header both prints it
        /// and styles a conflict apart from an ordinary change (see
        /// `DiffLineStyle.statusEmphasis(for:)`), which a string cannot answer.
        let status: GitDiffFile.Status
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
        enum Kind: Sendable {
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
        /// The source line's own text: `range` minus the truncation marker. A
        /// syntax highlight may only ever be applied here.
        ///
        /// Equal to `range` for every line that carries no marker, the `+`/`-`
        /// cue being drawn in the gutter rather than kept in the text.
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

    /// How big the diff is, as the refresh log reports it: the source lines it
    /// carries, the largest file's share of them, and its longest single line in
    /// characters.
    ///
    /// Measured over the *diff's* lines rather than the rendered ones — budgets
    /// and display truncation included — because that is what makes the numbers
    /// diagnostic: a minified bundle's multi-megabyte line is exactly what a
    /// freeze report needs named, and the document renders a short prefix of it.
    /// Accumulated in `init`, which already walks every line of every file, since
    /// the diff view logs this on each FSEvents-driven refresh and a pass of its
    /// own would walk the whole diff again on the main actor.
    struct Shape: Sendable, Equatable {
        var totalLines = 0
        var maxFileLines = 0
        var maxLineLen = 0
    }

    let text: String
    /// `text`'s length in UTF-16 units — the unit every span here counts in.
    /// Accumulated as the text is built, because asking a Swift `String` for it
    /// walks the whole document, and the renderer asks once per file painted.
    let textLength: Int
    let files: [FileSpan]
    let lines: [LineSpan]
    let shape: Shape

    init(diff: GitDiff) {
        var text = ""
        // Tracked as the text grows: ranges must be recorded at append time —
        // searching the finished string for a span would be both quadratic and
        // ambiguous — and asking a Swift String for its UTF-16 length is O(n).
        var offset = 0
        var files: [FileSpan] = []
        var lines: [LineSpan] = []
        var shape = Shape()
        var remainingTotal = Self.maxTotalLines

        /// Appends one paragraph and records its span. `suffixLength` is the
        /// UTF-16 length of the trailing commentary carved out of `body` that
        /// `contentRange` must exclude — the truncation marker, and nothing else
        /// so far.
        func append(
            _ body: String, kind: LineSpan.Kind, number: Int? = nil, fileIndex: Int,
            suffixLength: Int = 0, truncated: Bool = false
        ) {
            let paragraph = Self.flatteningSeparators(body)
            let length = paragraph.utf16.count
            text += paragraph
            text += "\n"
            lines.append(LineSpan(
                kind: kind, number: number,
                range: NSRange(location: offset, length: length),
                contentRange: NSRange(location: offset, length: length - suffixLength),
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
                        let marker = display.truncated ? Self.truncationMarker : ""
                        // No `+`/`-` cue in the text: it is drawn in the gutter, by
                        // `DiffGutterRuler`. Keeping it here would indent a line's
                        // first display row by one character while its wrapped rows
                        // started at the container's edge, and would put a
                        // rendering artefact inside every selection and copy.
                        append(
                            display.text + marker,
                            kind: LineSpan.Kind(line.kind),
                            number: DiffLineStyle.lineNumber(for: line), fileIndex: fileIndex,
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
            shape.totalLines += metrics.sourceLines
            shape.maxFileLines = max(shape.maxFileLines, metrics.sourceLines)
            shape.maxLineLen = max(shape.maxLineLen, metrics.longestLine)
            files.append(FileSpan(
                id: file.id, title: Self.title(of: file), status: file.status,
                insertions: metrics.insertions, deletions: metrics.deletions,
                gutterWidth: metrics.gutterWidth,
                range: NSRange(location: fileStart, length: offset - fileStart),
                firstLineIndex: firstLineIndex, lineCount: lines.count - firstLineIndex))
        }

        self.text = text
        self.textLength = offset
        self.files = files
        self.lines = lines
        self.shape = shape
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

    /// The 1-based source line numbers one file's rendered lines carry, split by
    /// the side of the diff they name — `new` for additions and context, `old`
    /// for deletions. Empty for a file this document does not have.
    ///
    /// These are the only lines a syntax highlight is ever looked up for, so a
    /// side with no numbers at all has nothing to color: highlighting it, and
    /// even reading its text, is work whose every result is discarded.
    func renderedLineNumbers(ofFileAt fileIndex: Int) -> (new: Set<Int>, old: Set<Int>) {
        guard files.indices.contains(fileIndex) else { return ([], []) }
        let file = files[fileIndex]
        var newNumbers: Set<Int> = []
        var oldNumbers: Set<Int> = []
        for line in lines[file.firstLineIndex..<(file.firstLineIndex + file.lineCount)] {
            // The same three conditions `DiffTextAssembly.applyHighlight` skips
            // on: chrome carries no source line, and a truncated line's content
            // is only a prefix of one, so neither is ever looked up.
            guard let kind = line.diffKind, let number = line.number, !line.truncated else { continue }
            if kind == .deletion {
                oldNumbers.insert(number)
            } else {
                newNumbers.insert(number)
            }
        }
        return (newNumbers, oldNumbers)
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

    /// Header stats, gutter width and the file's share of the diff's `Shape`,
    /// computed over **all** of a file's lines including any the budgets hide: the
    /// header describes the change, not what got rendered. Same arithmetic as the
    /// previous row-based renderer, so the gutter keeps its width.
    private static func metrics(
        of file: GitDiffFile
    ) -> (insertions: Int, deletions: Int, gutterWidth: CGFloat, sourceLines: Int, longestLine: Int) {
        var insertions = 0
        var deletions = 0
        var widestLineNumber = 0
        var sourceLines = 0
        var longestLine = 0
        for hunk in file.hunks {
            sourceLines += hunk.lines.count
            for line in hunk.lines {
                switch line.kind {
                case .addition: insertions += 1
                case .deletion: deletions += 1
                case .context: break
                }
                if let old = line.oldLineNumber { widestLineNumber = max(widestLineNumber, old) }
                if let new = line.newLineNumber { widestLineNumber = max(widestLineNumber, new) }
                longestLine = max(longestLine, line.content.count)
            }
        }
        // The widest number sets the width so the column never truncates (e.g.
        // 5-digit numbers in a large file): one number plus trailing padding,
        // with a floor so short files don't get a cramped column.
        let maxDigits = max(String(widestLineNumber).count, 1)
        return (insertions, deletions, max(CGFloat(maxDigits * 9 + 12), 36), sourceLines, longestLine)
    }

    /// The path as the header bar shows it: both sides joined for a rename,
    /// otherwise whichever side exists (a deletion has no new path).
    private static func title(of file: GitDiffFile) -> String {
        if file.oldPath.isEmpty { return file.newPath }
        if file.newPath.isEmpty { return file.oldPath }
        return file.oldPath == file.newPath ? file.newPath : "\(file.oldPath) → \(file.newPath)"
    }
}
