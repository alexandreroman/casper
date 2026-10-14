import AppKit

extension NSAppearance {
    /// Whether this appearance belongs to the dark family (`darkAqua`, `vibrantDark`,
    /// and the accessibility variants). `bestMatch` collapses every variant onto one
    /// of the two base appearances, so no name has to be listed here.
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
