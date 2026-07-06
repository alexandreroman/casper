import CasperGit
import SwiftUI

/// Pure mapping from a diff line kind to its rendering cues. Kept out of the view
/// so the (color-independent) prefix is unit-testable and the view stays
/// declarative.
enum DiffLineStyle {
    /// Bright accent hues for the leading stripe and the +N −N stat badges,
    /// saturated enough to read against the dark diff row backgrounds. The
    /// row backgrounds derive from these at low opacity, so they read as dark
    /// green/red bands over the dark UI (and light washes in light mode).
    static var insertionTint: Color { Color(red: 0.30, green: 0.72, blue: 0.44) }
    static var deletionTint: Color { Color(red: 0.85, green: 0.40, blue: 0.38) }

    static func prefix(for kind: GitDiffLine.Kind) -> String {
        switch kind {
        case .addition: return "+"
        case .deletion: return "-"
        case .context: return " "
        }
    }

    /// Dark, theme-aware row wash: the accent hue at low opacity reads as a
    /// dark green/red band over the dark UI.
    static func background(for kind: GitDiffLine.Kind) -> Color {
        switch kind {
        case .addition: return insertionTint.opacity(0.18)
        case .deletion: return deletionTint.opacity(0.18)
        case .context: return Color.clear
        }
    }

    /// Solid leading accent stripe (brighter than the background wash).
    static func accent(for kind: GitDiffLine.Kind) -> Color {
        switch kind {
        case .addition: return insertionTint
        case .deletion: return deletionTint
        case .context: return Color.clear
        }
    }
}
