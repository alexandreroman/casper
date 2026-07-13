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

    /// Whether `text` is too large to be worth highlighting (see
    /// `maxHighlightBytes`). Measured in UTF-8 bytes to bound memory use.
    static func exceedsHighlightBudget(_ text: String) -> Bool {
        text.utf8.count > maxHighlightBytes
    }

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
        // Skip huge generated files: their long lines are truncated at display
        // anyway (see `DiffLineStyle.maxDisplayLineLength`), so highlighting a
        // minified/generated blob only burns CPU and memory off-actor.
        if exceedsHighlightBudget(text) {
            return nil
        }

        // The app forces global dark appearance, so the diff view is always dark.
        let colors: HighlightColors = .dark(.github)

        let highlighted: AttributedString
        do {
            highlighted = try await Highlight().attributedText(text, language: language, colors: colors)
        } catch {
            return nil
        }

        // Safety net: only hand back a per-line array the caller can index by
        // line number; any mismatch (e.g. the library trimming edge
        // whitespace) falls back to neutral rather than misaligning colors.
        let lines = splitLines(highlighted)
        guard lines.count == 1 + text.lazy.filter({ $0 == "\n" }).count else {
            return nil
        }
        return lines
    }

    /// Splits an attributed string into one element per "\n"-delimited line,
    /// preserving each run's attributes but dropping the font so only colors
    /// remain. Empty segments are kept so blank lines stay aligned.
    private static func splitLines(_ attributed: AttributedString) -> [AttributedString] {
        var lines: [AttributedString] = []
        var current = AttributedString()

        for run in attributed.runs {
            var attributes = run.attributes
            attributes.font = nil

            let segments = String(attributed[run.range].characters).components(separatedBy: "\n")
            for (index, segment) in segments.enumerated() {
                // Every segment past the first starts a fresh line.
                if index > 0 {
                    lines.append(current)
                    current = AttributedString()
                }
                if !segment.isEmpty {
                    current.append(AttributedString(segment, attributes: attributes))
                }
            }
        }

        lines.append(current)
        return lines
    }
}
