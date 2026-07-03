import AppKit
import SwiftUI

/// A GitHub Primer Octicons glyph (MIT license) rendered via macOS's native SVG
/// decoding — `NSImage` reads the SVG markup directly, so no SVG parser or
/// third-party dependency is needed. Each glyph is marked as a template image so
/// a caller's `.foregroundStyle(...)` (or an enclosing control's tint) colors it
/// like an SF Symbol.
struct Octicon: View {
    enum Name: String { case gitBranch, terminal, globe }

    let name: Name
    var size: CGFloat = 16

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
        .terminal: """
        <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16"><path d="M0 2.75C0 1.784.784 1 1.75 1h12.5c.966 0 1.75.784 1.75 1.75v10.5A1.75 1.75 0 0 1 14.25 15H1.75A1.75 1.75 0 0 1 0 13.25Zm1.75-.25a.25.25 0 0 0-.25.25v10.5c0 .138.112.25.25.25h12.5a.25.25 0 0 0 .25-.25V2.75a.25.25 0 0 0-.25-.25ZM7.25 8a.749.749 0 0 1-.22.53l-2.25 2.25a.749.749 0 0 1-1.275-.326.749.749 0 0 1 .215-.734L5.44 8 3.72 6.28a.749.749 0 0 1 .326-1.275.749.749 0 0 1 .734.215l2.25 2.25c.141.14.22.331.22.53Zm1.5 1.5h3a.75.75 0 0 1 0 1.5h-3a.75.75 0 0 1 0-1.5Z"/></svg>
        """,
        .globe: """
        <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16"><path d="M8 0a8 8 0 1 1 0 16A8 8 0 0 1 8 0ZM5.78 8.75a9.64 9.64 0 0 0 1.363 4.177c.255.426.542.832.857 1.215.245-.296.551-.705.857-1.215A9.64 9.64 0 0 0 10.22 8.75Zm4.44-1.5a9.64 9.64 0 0 0-1.363-4.177c-.307-.51-.612-.919-.857-1.215a9.927 9.927 0 0 0-.857 1.215A9.64 9.64 0 0 0 5.78 7.25Zm-5.944 1.5H1.543a6.507 6.507 0 0 0 4.666 5.5c-.123-.181-.24-.365-.352-.552-.715-1.192-1.437-2.874-1.581-4.948Zm-2.733-1.5h2.733c.144-2.074.866-3.756 1.58-4.948.12-.197.237-.381.353-.552a6.507 6.507 0 0 0-4.666 5.5Zm10.181 1.5c-.144 2.074-.866 3.756-1.58 4.948-.12.197-.237.381-.353.552a6.507 6.507 0 0 0 4.666-5.5Zm2.733-1.5a6.507 6.507 0 0 0-4.666-5.5c.123.181.24.365.353.552.714 1.192 1.436 2.874 1.58 4.948Z"/></svg>
        """,
    ]

    // Decoded once per name and cached. `NSImage(data:)` yields a vector
    // `_NSSVGImageRep` on macOS 14+; marking it a template lets
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
            // Defensive: decoding never fails on macOS 14, but keep layout
            // stable if it ever does rather than crashing.
            Color.clear
                .frame(width: size, height: size)
        }
    }
}
