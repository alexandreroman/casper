import CasperGit
import SwiftUI

/// Pure mapping from a diff line kind to its rendering cues. Kept out of the view
/// so the (color-independent) prefix is unit-testable and the view stays
/// declarative.
enum DiffLineStyle {
    /// The single source of truth for the diff add/delete color convention. Call
    /// sites layer their own opacity on top of these base hues (line backgrounds
    /// use a light wash, badge text a near-solid tint).
    static var insertionTint: Color { .green }
    static var deletionTint: Color { .red }

    static func prefix(for kind: GitDiffLine.Kind) -> String {
        switch kind {
        case .addition: return "+"
        case .deletion: return "-"
        case .context: return " "
        }
    }

    static func color(for kind: GitDiffLine.Kind) -> Color {
        switch kind {
        case .addition: return insertionTint
        case .deletion: return deletionTint
        case .context: return .primary
        }
    }

    static func background(for kind: GitDiffLine.Kind) -> Color {
        switch kind {
        case .addition: return insertionTint.opacity(0.12)
        case .deletion: return deletionTint.opacity(0.12)
        case .context: return Color.clear
        }
    }

    /// Solid tint for the row's leading accent stripe. Context lines get no
    /// stripe (clear), mirroring GitHub's gutter accent.
    static func accent(for kind: GitDiffLine.Kind) -> Color {
        switch kind {
        case .addition: return insertionTint
        case .deletion: return deletionTint
        case .context: return Color.clear
        }
    }
}
