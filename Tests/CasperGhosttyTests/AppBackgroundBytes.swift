import AppKit
@testable import CasperGhostty

/// The RGB bytes of the content background Casper resolves for `name`. The OS owns
/// that colour and it differs across macOS versions (CI runs a macos-15 leg), so
/// tests compare against it rather than hard-coding a resolved value.
func contentBackgroundBytes(for name: NSAppearance.Name) -> [UInt8] {
    let hex = GhosttyDefaultConfig.contentBackgroundHex(for: name).dropFirst()
    return stride(from: 0, to: 6, by: 2).map { offset in
        let start = hex.index(hex.startIndex, offsetBy: offset)
        return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
    }
}
