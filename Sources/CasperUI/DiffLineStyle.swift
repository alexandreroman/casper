import CasperGit
import SwiftUI

/// Pure mapping from a diff line kind to its rendering cues. Kept out of the
/// view so this (color-independent) logic is unit-testable and the view stays
/// declarative.
enum DiffLineStyle {
    /// Accent hues for the leading stripe, the +/- prefix, the gutter line
    /// number, and the +N -N stat badges. Sampled from Claude Code's own diff
    /// rendering so Casper's diff view reads the same way.
    static let insertionTint = Color(red: 0.529, green: 0.757, blue: 0.388)
    static let deletionTint = Color(red: 0.725, green: 0.416, blue: 0.369)

    /// Concrete gutter line-number color for context lines, sitting beside
    /// `accent(for:)` so all three number tints are named in one place. A plain
    /// `Color` rather than the hierarchical `.tertiary` style: `DiffGutterRuler`
    /// draws the numbers itself and converts this to an `NSColor` once, which a
    /// style that only resolves against a rendering context could not supply.
    static let contextNumberTint = Color(nsColor: .tertiaryLabelColor)

    /// Caps a single diff line's length in characters, complementing
    /// `DiffDocument.maxLinesPerFile` (which caps the line *count*). Without it,
    /// a multi-megabyte single line — a minified JS/CSS bundle, a one-line
    /// lockfile, or an inlined base64 blob — makes TextKit line-wrapping run on
    /// the main thread and freezes the app. Real source lines are far shorter
    /// (the 120-column convention), so this only ever trims generated content.
    static let maxDisplayLineLength = 2000

    /// Caps `content` to `maxDisplayLineLength` characters for display. Returns
    /// the original string and `false` when it fits; otherwise the leading
    /// `maxDisplayLineLength` characters and `true`. Exactly the cap length is
    /// *not* truncated. Runs in O(cap) — it walks at most `maxDisplayLineLength`
    /// indices rather than counting the (possibly megabyte-long) string.
    static func truncatedForDisplay(_ content: String) -> (text: String, truncated: Bool) {
        let cap = content.index(content.startIndex, offsetBy: maxDisplayLineLength, limitedBy: content.endIndex)
        guard let cap, cap < content.endIndex else {
            return (content, false)
        }
        return (String(content[content.startIndex..<cap]), true)
    }

    /// The `+`/`-` cue for a changed line, or `nil` for a context line — which
    /// has nothing to announce.
    ///
    /// Drawn by `DiffGutterRuler` in a column of its own, *not* prepended to the
    /// line's text: a cue in the text indents a wrapped line's first display row
    /// by one character while its later rows start at the container's edge, and
    /// puts a rendering artefact inside every selection and copy.
    static func cue(for kind: GitDiffLine.Kind) -> String? {
        switch kind {
        case .addition: return "+"
        case .deletion: return "-"
        case .context: return nil
        }
    }

    /// Solid, saturated row background — sampled from Claude Code's own diff
    /// rendering (not derived from the accent tint, which is too pale at any
    /// reasonable opacity to match). The app is dark-only
    /// (`AppDelegate.swift` forces `.darkAqua`), so there is no light-mode
    /// variant to maintain.
    static func background(for kind: GitDiffLine.Kind) -> Color {
        switch kind {
        case .addition: return Color(red: 0.082, green: 0.149, blue: 0.024)
        case .deletion: return Color(red: 0.188, green: 0.043, blue: 0.012)
        case .context: return Color.clear
        }
    }

    /// Solid leading accent stripe, also used to tint the +/- prefix and the
    /// gutter line number on changed lines.
    static func accent(for kind: GitDiffLine.Kind) -> Color {
        switch kind {
        case .addition: return insertionTint
        case .deletion: return deletionTint
        case .context: return Color.clear
        }
    }

    /// How a file's status word is set in the diff file header.
    ///
    /// Most statuses are chrome: `modified` beside a file's name asks nothing of the
    /// reader. Two are not, which is the whole reason this is a mapping and not one
    /// flat style.
    enum StatusEmphasis: Equatable {
        /// Secondary label at the chrome size — what every ordinary status gets.
        case chrome
        /// Tinted and bold. `conflicted` only: the file holds conflict markers rather
        /// than an author's changes, which is the most consequential thing a diff
        /// header can say, and the header is the only place the diff says it.
        case warning(Color)
        /// Tinted down. `unreadable` only: libgit2 could not open the file at all, a
        /// non-answer rather than something to act on.
        case muted(Color)
    }

    /// How the file header sets `status`. The warning tint is the deletion tint the
    /// removed rows already carry rather than a colour of its own, so the diff view
    /// keeps a single palette.
    static func statusEmphasis(for status: GitDiffFile.Status) -> StatusEmphasis {
        switch status {
        case .conflicted: return .warning(deletionTint)
        case .unreadable: return .muted(Color(nsColor: .tertiaryLabelColor))
        case .added, .deleted, .modified, .renamed, .copied, .typechange, .unmodified: return .chrome
        }
    }

    /// The single gutter line number for a diff line: the old (HEAD) line
    /// number for a deletion, the new (working-tree) line number for an
    /// addition or context line. Matches git's own line correspondence and
    /// collapses the gutter to one column, as in Claude Code's diff
    /// rendering, instead of two side-by-side old/new columns.
    static func lineNumber(for line: GitDiffLine) -> Int? {
        line.kind == .deletion ? line.oldLineNumber : line.newLineNumber
    }
}
