import HighlightSwift
import SwiftUI

/// Pure syntax-highlighting helper for the diff view. It turns a full file's
/// text into one colored `AttributedString` per source line; the diff view reads
/// nothing but their foreground colors (`DiffTextAssembly.applyHighlight`), so its
/// own monospaced font applies uniformly. Highlighting runs off the main actor
/// and never propagates errors — callers fall back to neutral text when this
/// returns `nil`.
enum DiffHighlighter {
    /// Maps a file path's extension to a highlight.js language alias, or `nil`
    /// when the extension is unknown (the caller then renders neutral text; no
    /// auto-detection is attempted). highlight.js parses HTML under its "xml"
    /// grammar, so `html`/`htm` map to `xml`.
    static func language(forPath path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "go": return "go"
        case "js", "jsx", "mjs", "cjs": return "javascript"
        case "ts", "tsx": return "typescript"
        case "py": return "python"
        case "rs": return "rust"
        case "html", "htm": return "xml"
        case "css": return "css"
        case "scss": return "scss"
        case "sh", "bash", "zsh": return "bash"
        case "md", "markdown": return "markdown"
        case "yaml", "yml": return "yaml"
        case "json": return "json"
        case "java": return "java"
        default: return nil
        }
    }

    /// Makes HighlightSwift's resource bundle reachable from where its
    /// generated `Bundle.module` accessor looks — the `.app` bundle root
    /// (`Bundle.main.bundleURL`), a sibling of `Contents/`. That accessor
    /// calls `fatalError` when the bundle is missing, so we mirror it there
    /// from `Contents/Resources/` (where packaging ships it as a sealed
    /// resource) once, before the first highlight call reaches into the
    /// library. Code signing only seals `Contents/`, so the root copy must be
    /// created at runtime rather than baked into the shipped bundle.
    ///
    /// Best-effort: any failure (missing source, read-only/translocated first
    /// launch before the app is moved to /Applications) leaves the flag
    /// `false` and `highlightedLines` falls back to neutral text instead of
    /// crashing. Static-let initialization is lazy and runs exactly once even
    /// under concurrent highlight calls.
    private static let resourceBundleReady: Bool = {
        let fileManager = FileManager.default
        let bundleName = "HighlightSwift_HighlightSwift.bundle"
        let target = Bundle.main.bundleURL.appendingPathComponent(bundleName)
        if fileManager.fileExists(atPath: target.path) {
            return true
        }
        if let source = Bundle.main.resourceURL?.appendingPathComponent(bundleName) {
            try? fileManager.copyItem(at: source, to: target)
        }
        return fileManager.fileExists(atPath: target.path)
    }()

    /// Files larger than this are rendered as neutral text instead of being
    /// highlighted: highlighting a minified/generated blob is wasted work, since
    /// its long lines are truncated in the view anyway (see
    /// `DiffLineStyle.maxDisplayLineLength`).
    static let maxHighlightBytes = 512 * 1024

    /// One reused HighlightSwift instance (it keeps a single warm JavaScriptCore
    /// context). A fresh `Highlight()` per call spins up a new `JSContext` each
    /// time; under rapid diff refreshes those pile up and JavaScriptCore never
    /// returns the VM-heap memory to the OS, so RSS grows into the gigabytes and
    /// never recedes. Reusing one instance serialises highlighting through its
    /// `HLJS` actor and bounds memory (measured ~7.5× less).
    private static let highlighter = Highlight()

    /// The highlight palette for `colorScheme`. Its colours are baked into the
    /// returned text, so a scheme change means highlighting again.
    static func colors(for colorScheme: ColorScheme) -> HighlightColors {
        colorScheme == .dark ? .dark(.github) : .light(.github)
    }

    /// Highlights `text` as a whole (full-file context matters, so lines are
    /// never highlighted in isolation) and returns one `AttributedString` per
    /// source line, indexable by 1-based line number.
    ///
    /// Returns `nil` when the language is unknown, the text is empty, the
    /// HighlightSwift resource bundle cannot be made available (see
    /// `resourceBundleReady`), highlighting throws, or the output cannot be lined
    /// up with `text`'s lines (see `lines(fromLibraryOutput:alignedTo:)`) — in
    /// every such case the caller falls back to neutral text.
    ///
    /// The palette follows `colorScheme` (see `colors(for:)`).
    static func highlightedLines(
        of text: String, forPath path: String, colorScheme: ColorScheme
    ) async -> [AttributedString]? {
        guard let language = language(forPath: path), !text.isEmpty, resourceBundleReady else {
            return nil
        }

        let source = normalizingLineEndings(text)
        let highlighted: AttributedString
        do {
            highlighted = try await highlighter.attributedText(
                source, language: language, colors: colors(for: colorScheme))
        } catch {
            return nil
        }
        return lines(fromLibraryOutput: highlighted, alignedTo: source)
    }

    /// `text` with its line breaks matched to the diff's lines: every CRLF turned
    /// into a bare LF, and every other paragraph separator — a lone CR above all —
    /// into a space.
    ///
    /// The diff's own lines arrive with a CRLF's CR already stripped
    /// (`Repository.mapLine`), and Git cuts lines at LF alone, so `DiffDocument`
    /// shows any other separator as a space on the line it sits in
    /// (`DiffDocument.paragraphSeparators`). The library's HTML import would
    /// instead turn a lone CR into a line break of its own, shifting every later
    /// line. Doing both up front keeps the lines the library returns the diff's
    /// lines, at the diff's lengths.
    static func normalizingLineEndings(_ text: String) -> String {
        let withBareLineFeeds = text.replacingOccurrences(of: "\r\n", with: "\n")
        // Scalar by scalar: the separators are scalars, and a `Character` can
        // hold more than one of them.
        var normalized = String.UnicodeScalarView()
        normalized.reserveCapacity(withBareLineFeeds.unicodeScalars.count)
        for scalar in withBareLineFeeds.unicodeScalars {
            let isSeparatorInsideALine = scalar != "\n" && DiffDocument.paragraphSeparators.contains(scalar)
            normalized.append(isSeparatorInsideALine ? " " : scalar)
        }
        return String(normalized)
    }

    /// Lines HighlightSwift's output up with the source it highlighted: one
    /// element per line of `source`, indexable by line number, or `nil` when the
    /// two cannot be lined up — the caller then falls back to neutral text rather
    /// than misaligning colors.
    ///
    /// The library trims whitespace and newlines off both ends of highlight.js's
    /// HTML, not of the text, so its output starts at the first line with visible
    /// text and usually stops at the last; whitespace a grammar wrapped in an edge
    /// span is out of the trim's reach and survives. The blank lines trimmed off
    /// the start come back as empty elements ahead of the output, and the end is
    /// padded with empty elements up to the source's line count. A first or last
    /// line that lost edge spaces then fails `DiffTextAssembly.applyHighlight`'s
    /// per-line length check and stays neutral on its own.
    ///
    /// That trim is the only change the output may carry: its text must be the
    /// trimmed source followed by, at most, the start of the source's trailing
    /// whitespace. Whitespace kept at the trailing edge sits exactly where the
    /// source has it, so its line breaks only stand in for some of the padding.
    /// Any other change — a CR the HTML import turned into a line break, a dropped
    /// NUL, leading newlines kept in a span and then counted again as trimmed —
    /// can move a line break, and a line count that still agrees would paint
    /// colors on the wrong lines.
    ///
    /// Line feeds are counted over **scalars**, matching how `splitLines` cuts: a
    /// CRLF pair is a single `Character`, which a `"\n"` literal never equals.
    ///
    /// Not `private`, for the same reason as `splitLines`: `DiffHighlighterTests`
    /// drives it with the shape the library produces.
    static func lines(
        fromLibraryOutput highlighted: AttributedString, alignedTo source: String
    ) -> [AttributedString]? {
        let output = String(highlighted.characters)
        let leadingWhitespace = source.unicodeScalars.prefix { CharacterSet.whitespacesAndNewlines.contains($0) }
        let sourceAfterLeadingWhitespace = String(source.unicodeScalars[leadingWhitespace.endIndex...])
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sourceAfterLeadingWhitespace.hasPrefix(output), output.hasPrefix(trimmedSource) else {
            return nil
        }
        let sourceLineCount = 1 + source.unicodeScalars.lazy.filter { $0 == "\n" }.count
        let trimmedLeadingLineCount = leadingWhitespace.lazy.filter { $0 == "\n" }.count

        var lines = Array(repeating: AttributedString(), count: trimmedLeadingLineCount)
        lines += splitLines(highlighted)
        lines += Array(repeating: AttributedString(), count: sourceLineCount - lines.count)
        return lines
    }

    /// Splits an attributed string into one element per "\n"-delimited line,
    /// preserving each run's attributes. Empty segments are kept so blank lines
    /// stay aligned.
    ///
    /// Sliced straight out of `attributed` rather than rebuilt from `String`
    /// segments: this runs over a whole file's worth of runs, and going through
    /// `String(…characters)` + `components(separatedBy:)` + one `append` per
    /// segment allocated three times per run and re-walked the accumulated run
    /// list on every append.
    ///
    /// Not `private`: `highlightedLines` cannot run under XCTest at all (it
    /// needs HighlightSwift's resource bundle next to `Bundle.main`, which is
    /// the toolchain's `usr/bin` there), so `DiffHighlighterTests` pins the
    /// split — line endings above all — on this directly.
    static func splitLines(_ attributed: AttributedString) -> [AttributedString] {
        var lines: [AttributedString] = []
        var lineStart = attributed.startIndex

        // Scalar by scalar, so a "\r\n" — one `Character`, two scalars — cuts at
        // its LF the way the source text's own line count does.
        for index in attributed.unicodeScalars.indices where attributed.unicodeScalars[index] == "\n" {
            lines.append(AttributedString(attributed[lineStart..<index]))
            lineStart = attributed.unicodeScalars.index(after: index)
        }
        lines.append(AttributedString(attributed[lineStart..<attributed.endIndex]))
        return lines
    }
}
