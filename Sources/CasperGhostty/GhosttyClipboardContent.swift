import Foundation
import GhosttyKit

/// One representation of clipboard contents crossing the libghostty boundary: a MIME type and
/// its bytes, mirroring upstream Ghostty's `Ghostty.ClipboardContent`.
///
/// libghostty's `ghostty_clipboard_content_s` is binary-safe: `data` comes with an explicit
/// `len` and is not necessarily NUL-terminated, so it is copied by length and never read as a
/// C string. The MIME type, by contrast, is an ordinary NUL-terminated C string. The value
/// owns its copy, which is what lets a request outlive the callback whose borrowed C memory it
/// was read from.
///
/// Casper serves and writes plain text only — a deliberate scope choice — so the text entry is
/// the one it ever reads (`plainTextEntry`); other representations are carried through
/// untouched.
struct GhosttyClipboardContent: Equatable {
    /// The canonical plain-text MIME type, the one libghostty asks for on a paste or a read.
    static let plainTextMIME = "text/plain"

    let mime: String
    let data: Data

    init(mime: String, data: Data) {
        self.mime = mime
        self.data = data
    }

    /// A plain-text representation of `text`, encoded as UTF-8.
    init(plainText text: String) {
        self.init(mime: Self.plainTextMIME, data: Data(text.utf8))
    }

    /// Copy `content` out of libghostty's memory: exactly `len` bytes of `data`. Nil for an
    /// entry with no MIME type, which names no representation at all.
    init?(_ content: ghostty_clipboard_content_s) {
        guard let mime = content.mime else { return nil }
        self.mime = String(cString: mime)
        if let bytes = content.data, content.len > 0 {
            self.data = Data(bytes: bytes, count: content.len)
        } else {
            self.data = Data()
        }
    }

    /// Copy every entry of a C array of `count` representations.
    static func array(
        from pointer: UnsafePointer<ghostty_clipboard_content_s>?, count: Int
    ) -> [GhosttyClipboardContent] {
        guard let pointer, count > 0 else { return [] }
        return UnsafeBufferPointer(start: pointer, count: count).compactMap { GhosttyClipboardContent($0) }
    }

    /// The data decoded as UTF-8. Invalid sequences are repaired with U+FFFD, so a malformed
    /// byte costs one character rather than the whole text.
    var text: String { String(decoding: data, as: UTF8.self) }

    /// Whether this entry is plain text.
    var isPlainText: Bool { Self.isPlainText(mime: mime) }

    /// Whether `mime` names plain text. The list is libghostty's own (`isTextMime` in
    /// `src/terminal/clipboard.zig`), so Casper reads exactly the entries core itself treats
    /// as text.
    static func isPlainText(mime: String) -> Bool {
        ["text/plain", "text/plain;charset=utf-8", "UTF8_STRING", "TEXT", "STRING"].contains(mime)
    }
}

extension [GhosttyClipboardContent] {
    /// The first plain-text representation. A ⌘C write can carry several entries (plain text
    /// plus HTML, say), so the first entry is not assumed to be the text.
    var plainTextEntry: GhosttyClipboardContent? { first(where: \.isPlainText) }

    /// What a confirmation prompt shows for these contents, by upstream Ghostty's display
    /// rule: the plain text when there is some, a one-line summary per representation
    /// otherwise.
    var confirmationPreview: String {
        if let entry = plainTextEntry { return entry.text }
        return map { "\($0.mime) (\($0.data.count) bytes)" }.joined(separator: "\n")
    }
}

/// Copy a C array of `count` NUL-terminated MIME strings, skipping null entries.
func clipboardMIMEs(from pointer: UnsafePointer<UnsafePointer<CChar>?>?, count: Int) -> [String] {
    guard let pointer, count > 0 else { return [] }
    return UnsafeBufferPointer(start: pointer, count: count).compactMap { $0.map { String(cString: $0) } }
}
