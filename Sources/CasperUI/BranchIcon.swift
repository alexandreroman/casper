import AppKit
import SwiftUI

/// GitHub's Primer Octicons "git-branch" glyph (MIT license), rendered by
/// macOS's native SVG decoding — `NSImage` reads the SVG markup directly, so no
/// SVG parser or third-party dependency is needed. The image is marked as a
/// template so a caller's `.foregroundStyle(...)` tints it like an SF Symbol
/// (call sites use `.foregroundStyle(.secondary)`).
struct BranchIcon: View {
    var size: CGFloat = 16

    // Primer Octicons' `git-branch-16.svg` (viewBox "0 0 16 16"), verbatim.
    // Source: primer/octicons, MIT license.
    private static let octiconMarkup = """
    <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16"><path d="M9.5 3.25a2.25 2.25 0 1 1 3 2.122V6A2.5 2.5 0 0 1 10 8.5H6a1 1 0 0 0-1 1v1.128a2.251 2.251 0 1 1-1.5 0V5.372a2.25 2.25 0 1 1 1.5 0v1.836A2.493 2.493 0 0 1 6 7h4a1 1 0 0 0 1-1v-.628A2.25 2.25 0 0 1 9.5 3.25Zm-6 0a.75.75 0 1 0 1.5 0 .75.75 0 0 0-1.5 0Zm8.25-.75a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5ZM4.25 12a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Z"/></svg>
    """

    // Decoded once. `NSImage(data:)` yields a vector `_NSSVGImageRep` on macOS
    // 14+; marking it a template lets `.foregroundStyle(...)` tint it.
    private static let image: NSImage? = {
        guard let image = NSImage(data: Data(octiconMarkup.utf8)) else { return nil }
        image.isTemplate = true
        return image
    }()

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .frame(width: size, height: size)
        } else {
            // Defensive: decoding never fails on macOS 14, but keep layout
            // stable if it ever does rather than crashing.
            Color.clear
                .frame(width: size, height: size)
        }
    }
}
