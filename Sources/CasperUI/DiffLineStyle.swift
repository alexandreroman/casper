import AppKit
import CasperGit

/// The diff view's palette and per-kind rendering cues, as pure mappings the
/// AppKit renderer draws from: `DiffTextView` paints the row tints,
/// `DiffGutterRuler` the stripe, cue and number, `DiffStickyHeader` the status
/// and `+N −N` counts. Kept apart from the drawing so it is unit-testable.
///
/// Every colour is an `NSColor`, the type all three draw with. Each adaptive one
/// resolves against the drawing appearance at draw time, so the attribute
/// dictionaries that hold them follow a live Light/Dark switch without being
/// rebuilt. The title bar's badge, the one SwiftUI consumer, wraps them in
/// `Color(nsColor:)`.
enum DiffLineStyle {
    /// Accent hues for the leading stripe, the +/- cue, the gutter line number,
    /// and the +N -N stat badges. The dark values are sampled from Claude Code's
    /// own diff rendering so Casper's diff view reads the same way; the light ones
    /// come from GitHub's diff.
    static let insertionTint = adaptive(
        dark: NSColor(srgbRed: 0.529, green: 0.757, blue: 0.388, alpha: 1), light: srgb(0x1A7F37))
    static let deletionTint = adaptive(
        dark: NSColor(srgbRed: 0.725, green: 0.416, blue: 0.369, alpha: 1), light: srgb(0xCF222E))

    /// Solid, saturated row backgrounds (not derived from the accent tint, which
    /// is too pale at any reasonable opacity to match). The dark values are
    /// sampled from Claude Code's own diff rendering, the light ones from
    /// GitHub's diff.
    static let additionBackground = adaptive(
        dark: NSColor(srgbRed: 0.082, green: 0.149, blue: 0.024, alpha: 1), light: srgb(0xDAFBE1))
    static let deletionBackground = adaptive(
        dark: NSColor(srgbRed: 0.188, green: 0.043, blue: 0.012, alpha: 1), light: srgb(0xFFEBE9))

    /// Gutter line-number colour for context lines, beside `accent(for:)` so all
    /// three number tints are named in one place.
    static let contextNumberTint = NSColor.tertiaryLabelColor

    /// A colour that resolves to `dark` under a dark appearance and `light`
    /// otherwise, at draw time.
    private static func adaptive(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.isDark ? dark : light
        }
    }

    private static func srgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// The background behind one diff row, or `nil` for a context row — as for
    /// the hunk headers and notes that have no diff kind at all — which keeps the
    /// plain text background.
    ///
    /// `DiffTextView` fills it across the code column and `DiffGutterRuler`
    /// across the gutter, both from here, so the two halves of a row cannot come
    /// out different colours.
    static func rowTint(for kind: GitDiffLine.Kind) -> NSColor? {
        switch kind {
        case .addition: additionBackground
        case .deletion: deletionBackground
        case .context: nil
        }
    }

    /// The leading accent stripe of a changed row, also the colour of its cue and
    /// gutter line number; `nil` for a context row, which has no stripe.
    static func accent(for kind: GitDiffLine.Kind) -> NSColor? {
        switch kind {
        case .addition: insertionTint
        case .deletion: deletionTint
        case .context: nil
        }
    }

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
        case warning(NSColor)
        /// Tinted down. `unreadable` only: libgit2 could not open the file at all, a
        /// non-answer rather than something to act on.
        case muted(NSColor)
    }

    /// How the file header sets `status`. The warning tint is the deletion tint the
    /// removed rows already carry rather than a colour of its own, so the diff view
    /// keeps a single palette.
    static func statusEmphasis(for status: GitDiffFile.Status) -> StatusEmphasis {
        switch status {
        case .conflicted: return .warning(deletionTint)
        case .unreadable: return .muted(.tertiaryLabelColor)
        case .added, .deleted, .modified, .renamed: return .chrome
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
