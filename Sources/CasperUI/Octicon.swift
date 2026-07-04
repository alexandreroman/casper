import AppKit
import SwiftUI

/// A GitHub Primer Octicons glyph (MIT license) rendered via macOS's native SVG
/// decoding — `NSImage` reads the SVG markup directly, so no SVG parser or
/// third-party dependency is needed. Each glyph is marked as a template image so
/// a caller's `.foregroundStyle(...)` (or an enclosing control's tint) colors it
/// like an SF Symbol.
struct Octicon: View {
    enum Name: String { case gitBranch, fileDirectory }

    let name: Name
    var size: CGFloat

    init(_ name: Name, size: CGFloat = 16) {
        self.name = name
        self.size = size
    }

    // Primer Octicons' 16px glyphs (viewBox "0 0 16 16"), verbatim.
    // Source: primer/octicons, MIT license.
    private static let markup: [Name: String] = [
        .gitBranch: """
        <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16"><path d="M9.5 3.25a2.25 2.25 0 1 1 3 2.122V6A2.5 2.5 0 0 1 10 8.5H6a1 1 0 0 0-1 1v1.128a2.251 2.251 0 1 1-1.5 0V5.372a2.25 2.25 0 1 1 1.5 0v1.836A2.493 2.493 0 0 1 6 7h4a1 1 0 0 0 1-1v-.628A2.25 2.25 0 0 1 9.5 3.25Zm-6 0a.75.75 0 1 0 1.5 0 .75.75 0 0 0-1.5 0Zm8.25-.75a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5ZM4.25 12a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Z"/></svg>
        """,
        .fileDirectory: """
        <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16"><path d="M0 2.75C0 1.784.784 1 1.75 1H5c.55 0 1.07.26 1.4.7l.9 1.2a.25.25 0 0 0 .2.1h6.75c.966 0 1.75.784 1.75 1.75v8.5A1.75 1.75 0 0 1 14.25 15H1.75A1.75 1.75 0 0 1 0 13.25Zm1.75-.25a.25.25 0 0 0-.25.25v10.5c0 .138.112.25.25.25h12.5a.25.25 0 0 0 .25-.25v-8.5a.25.25 0 0 0-.25-.25H7.5c-.55 0-1.07-.26-1.4-.7l-.9-1.2a.25.25 0 0 0-.2-.1Z"/></svg>
        """,
    ]

    // Decoded once per name and cached. `NSImage(data:)` yields a vector
    // `_NSSVGImageRep` on macOS 15; marking it a template lets
    // `.foregroundStyle(...)` tint it.
    private static let images: [Name: NSImage] = markup.compactMapValues { svg in
        guard let image = NSImage(data: Data(svg.utf8)) else { return nil }
        image.isTemplate = true
        return image
    }

    var body: some View {
        if let image = Self.images[name] {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .frame(width: size, height: size)
        } else {
            // Defensive: decoding never fails on macOS 15, but keep layout
            // stable if it ever does rather than crashing.
            Color.clear
                .frame(width: size, height: size)
        }
    }
}
