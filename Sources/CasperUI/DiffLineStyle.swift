import CasperGit
import SwiftUI

/// Pure mapping from a diff line kind to its rendering cues. Kept out of the view
/// so the (color-independent) prefix is unit-testable and the view stays
/// declarative.
enum DiffLineStyle {
    static func prefix(for kind: GitDiffLine.Kind) -> String {
        switch kind {
        case .addition: return "+"
        case .deletion: return "-"
        case .context: return " "
        }
    }

    static func color(for kind: GitDiffLine.Kind) -> Color {
        switch kind {
        case .addition: return .green
        case .deletion: return .red
        case .context: return .primary
        }
    }

    static func background(for kind: GitDiffLine.Kind) -> Color {
        switch kind {
        case .addition: return Color.green.opacity(0.12)
        case .deletion: return Color.red.opacity(0.12)
        case .context: return Color.clear
        }
    }
}
