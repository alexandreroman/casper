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

    /// Concrete gutter line-number color for context lines. A plain `Color`
    /// rather than the hierarchical `.tertiary` style, so a row can pick one
    /// concrete color per line kind without erasing to `AnyShapeStyle`.
    static let contextNumberTint = Color(nsColor: .tertiaryLabelColor)

    static func prefix(for kind: GitDiffLine.Kind) -> String {
        switch kind {
        case .addition: return "+"
        case .deletion: return "-"
        case .context: return " "
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

    /// The single gutter line number for a diff line: the old (HEAD) line
    /// number for a deletion, the new (working-tree) line number for an
    /// addition or context line. Matches git's own line correspondence and
    /// collapses the gutter to one column, as in Claude Code's diff
    /// rendering, instead of two side-by-side old/new columns.
    static func lineNumber(for line: GitDiffLine) -> Int? {
        line.kind == .deletion ? line.oldLineNumber : line.newLineNumber
    }
}
