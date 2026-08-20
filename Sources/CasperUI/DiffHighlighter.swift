import HighlightSwift
import SwiftUI

/// Pure syntax-highlighting helper for the diff view. It turns a full file's
/// text into one colored `AttributedString` per source line, carrying only
/// foreground colors so the diff view can apply its own monospaced font
/// uniformly. Highlighting runs off the main actor and never propagates
/// errors — callers fall back to neutral text when this returns `nil`.
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
    /// context). Constructing a fresh `Highlight()` per call — as this did before —
    /// spun up a new `JSContext` each time; under rapid diff refreshes those piled
    /// up and JavaScriptCore never returned the VM-heap memory to the OS, so RSS
    /// grew into the gigabytes and never receded. Reusing one instance serialises
    /// highlighting through its `HLJS` actor and bounds memory (measured ~7.5× less).
    private static let highlighter = Highlight()

    /// Highlights `text` as a whole (full-file context matters, so lines are
    /// never highlighted in isolation) and returns one `AttributedString` per
    /// source line, indexable by 1-based line number.
    ///
    /// Returns `nil` when the language is unknown, the text is empty, the
    /// HighlightSwift resource bundle cannot be made available (see
    /// `resourceBundleReady`), highlighting throws, or the resulting line count
    /// does not match `text`'s — in every such case the caller falls back to
    /// neutral text.
    static func highlightedLines(of text: String, forPath path: String) async -> [AttributedString]? {
        guard let language = language(forPath: path), !text.isEmpty, resourceBundleReady else {
            return nil
        }

        // The app forces global dark appearance, so the diff view is always dark.
        let colors: HighlightColors = .dark(.github)

        let highlighted: AttributedString
        do {
            highlighted = try await highlighter.attributedText(text, language: language, colors: colors)
        } catch {
            return nil
        }

        // Safety net: only hand back a per-line array the caller can index by
        // line number; any mismatch (e.g. the library trimming edge
        // whitespace) falls back to neutral rather than misaligning colors.
        //
        // Counted over **scalars**, matching how `splitLines` cuts: a CRLF pair
        // is a single `Character` that equals neither "\n" nor "\r\n" when
        // compared against a "\n" literal, so counting characters answers 1 for
        // a whole CRLF file — the guard below then fails and the file silently
        // renders with no colors at all.
        let lines = splitLines(highlighted)
        guard lines.count == 1 + text.unicodeScalars.lazy.filter({ $0 == "\n" }).count else {
            return nil
        }
        return lines
    }

    /// Splits an attributed string into one element per "\n"-delimited line,
    /// preserving each run's attributes but dropping the font so only colors
    /// remain. Empty segments are kept so blank lines stay aligned.
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
        let fontless = droppingFonts(attributed)
        var lines: [AttributedString] = []
        var lineStart = fontless.startIndex

        // Scalar by scalar, so a "\r\n" — one `Character`, two scalars — cuts at
        // its LF the way the source text's own line count does.
        for index in fontless.unicodeScalars.indices where fontless.unicodeScalars[index] == "\n" {
            lines.append(AttributedString(fontless[lineStart..<index]))
            lineStart = fontless.unicodeScalars.index(after: index)
        }
        lines.append(AttributedString(fontless[lineStart..<fontless.endIndex]))
        return lines
    }

    /// `attributed` with the font dropped from every run, in both scopes, so the
    /// diff view's own uniform monospaced face survives.
    ///
    /// Both scopes, because a bare `font` is ambiguous with AppKit and SwiftUI
    /// both in scope and resolves to whichever one the compiler picks — which is
    /// how a font meant to be dropped stays on.
    ///
    /// The AppKit face goes out through `NSAttributedString` rather than through
    /// `appKit.font = nil`: every typed reference to that key — read, write or
    /// transform — instantiates a generic requiring `NSFont: Sendable`, a
    /// conformance AppKit marks unavailable. `NSAttributedString.Key.font` is a
    /// plain name wrapper with no such requirement. The bridge is lossless for
    /// what reaches here: HighlightSwift's output is itself decoded with
    /// `including: \.appKit` (which nests the Foundation scope), so every
    /// attribute survives the round trip.
    ///
    /// Done once for the whole string rather than per line, which also keeps
    /// slicing down to the substring copy it always wanted to be.
    private static func droppingFonts(_ attributed: AttributedString) -> AttributedString {
        var stripped = attributed
        stripped.swiftUI.font = nil

        let bridged = NSMutableAttributedString(stripped)
        bridged.removeAttribute(.font, range: NSRange(location: 0, length: bridged.length))
        // Decoding only throws when a value's type disagrees with the scope's, which
        // cannot happen for a string this very function just encoded from that scope.
        return (try? AttributedString(bridged, including: \.appKit)) ?? stripped
    }
}
