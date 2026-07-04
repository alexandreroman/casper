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

    /// Highlights `text` as a whole (full-file context matters, so lines are
    /// never highlighted in isolation) and returns one `AttributedString` per
    /// source line, indexable by 1-based line number.
    ///
    /// Returns `nil` when the language is unknown, the text is empty,
    /// highlighting throws, or the resulting line count does not match
    /// `text`'s — in every such case the caller falls back to neutral text.
    static func highlightedLines(
        of text: String, forPath path: String, dark: Bool
    ) async -> [AttributedString]? {
        guard let language = language(forPath: path), !text.isEmpty else {
            return nil
        }

        // GitHub reads well in both appearances; the diff view picks the
        // variant from the current color scheme via `dark`.
        let colors: HighlightColors = dark ? .dark(.github) : .light(.github)

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
        guard lines.count == text.components(separatedBy: "\n").count else {
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
