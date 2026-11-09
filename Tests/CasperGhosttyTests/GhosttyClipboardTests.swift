import AppKit
import GhosttyKit
import XCTest

@testable import CasperGhostty

final class GhosttyClipboardTests: XCTestCase {
    // MARK: - Decoding libghostty's clipboard contents

    /// `data` is binary-safe with an explicit `len` and need not be NUL-terminated, so exactly
    /// `len` bytes are read — never up to a terminator that may not exist. The buffer here has
    /// none, and carries trailing bytes past `len` that must not leak into the text; the
    /// multi-byte characters prove the bytes are decoded as UTF-8 rather than one per byte.
    func testContentDecodesExactlyLenBytesOfAnUnterminatedBuffer() throws {
        let text = "héllo — 世界"
        let bytes = Array(text.utf8) + Array("TRAILING-GARBAGE".utf8)
        let content = try bytes.withUnsafeBufferPointer { buffer in
            try buffer.withMemoryRebound(to: CChar.self) { chars in
                try "text/plain".withCString { mime in
                    try XCTUnwrap(GhosttyClipboardContent(
                        ghostty_clipboard_content_s(mime: mime, data: chars.baseAddress, len: text.utf8.count)))
                }
            }
        }

        XCTAssertEqual(content.mime, "text/plain")
        XCTAssertEqual(content.data.count, text.utf8.count)
        XCTAssertEqual(content.text, text)
    }

    /// An entry with no data reads as empty text rather than as a missing one.
    func testContentWithNoDataIsEmpty() throws {
        let content = try "text/plain".withCString { mime in
            try XCTUnwrap(GhosttyClipboardContent(ghostty_clipboard_content_s(mime: mime, data: nil, len: 0)))
        }

        XCTAssertEqual(content.text, "")
    }

    /// An entry with no MIME type names no representation, so copying a C array skips it and
    /// keeps the entries around it.
    func testContentWithoutAMimeTypeIsSkipped() {
        "text/plain".withCString { mime in
            "kept".withCString { data in
                let entries = [
                    ghostty_clipboard_content_s(mime: nil, data: data, len: 4),
                    ghostty_clipboard_content_s(mime: mime, data: data, len: 4),
                ]
                entries.withUnsafeBufferPointer { buffer in
                    XCTAssertEqual(
                        GhosttyClipboardContent.array(from: buffer.baseAddress, count: buffer.count),
                        [GhosttyClipboardContent(plainText: "kept")])
                }
            }
        }
    }

    func testNilContentArrayIsEmpty() {
        XCTAssertEqual(GhosttyClipboardContent.array(from: nil, count: 0), [])
    }

    /// A ⌘C write can carry several representations, and the plain text need not come first:
    /// the text entry is picked by its MIME type, not by its position.
    func testPlainTextEntryIsPickedFromAMultiEntryArray() {
        let html = GhosttyClipboardContent(mime: "text/html", data: Data("<b>bold</b>".utf8))
        let plain = GhosttyClipboardContent(plainText: "bold")
        let contents = [html, plain]

        XCTAssertEqual(contents.plainTextEntry, plain)
        XCTAssertEqual(contents.confirmationPreview, "bold")
    }

    /// The charset-qualified spelling is plain text too.
    func testCharsetQualifiedPlainTextIsPlainText() {
        let entry = GhosttyClipboardContent(mime: "text/plain;charset=utf-8", data: Data("hi".utf8))

        XCTAssertEqual([entry].plainTextEntry?.text, "hi")
    }

    /// With no text to show, the prompt summarises each representation instead, so the user
    /// still sees what would be handed over.
    func testPreviewWithoutPlainTextSummarisesEachRepresentation() {
        let contents = [
            GhosttyClipboardContent(mime: "image/png", data: Data(count: 42)),
            GhosttyClipboardContent(mime: "text/html", data: Data("<p></p>".utf8)),
        ]

        XCTAssertNil(contents.plainTextEntry)
        XCTAssertEqual(contents.confirmationPreview, "image/png (42 bytes)\ntext/html (7 bytes)")
    }

    /// The C MIME list is copied entry by entry, skipping the null ones.
    func testMimeListIsCopiedSkippingNullEntries() {
        "text/plain".withCString { plain in
            "image/png".withCString { png in
                let mimes: [UnsafePointer<CChar>?] = [plain, nil, png]
                mimes.withUnsafeBufferPointer { buffer in
                    XCTAssertEqual(
                        clipboardMIMEs(from: buffer.baseAddress, count: buffer.count), ["text/plain", "image/png"])
                }
            }
        }
    }

    // MARK: - What libghostty is configured to ask about

    /// The write gate only runs if libghostty is told to ask: `clipboard-write = ask` is what
    /// raises the `confirm` flag on the write callback (libghostty's own default is `allow`).
    /// Every gate test below passes with or without that line, because they drive the approval
    /// seam directly — which is exactly how a gate once shipped unreachable, green tests and
    /// all. Deleting the config line must fail here.
    func testDefaultConfigMakesLibghosttyAskBeforeAnUntrustedWrite() {
        XCTAssertTrue(
            GhosttyDefaultConfig.text(themes: nil).contains("clipboard-write = ask"),
            "without `clipboard-write = ask`, OSC 52 writes reach the pasteboard unprompted")
    }

    // MARK: - The `confirm` flag

    /// A user-initiated write (⌘C) reaches the pasteboard without asking anyone.
    @MainActor
    func testTrustedWriteNeedsNoApproval() {
        let pasteboard = testPasteboard()
        withApproval({ _ in
            XCTFail("a trusted write must not consult the confirmation policy")
            return false
        }, {
            GhosttyClipboardWrite.apply("copied", confirm: false, to: pasteboard)
        })

        XCTAssertEqual(pasteboard.string(forType: .string), "copied")
    }

    /// An approved OSC 52 write lands, and the text the user was shown is the text written.
    @MainActor
    func testApprovedUntrustedWriteIsApplied() {
        let pasteboard = testPasteboard()
        var confirmed: String?
        withApproval({ text in
            confirmed = text
            return true
        }, {
            GhosttyClipboardWrite.apply("from the terminal", confirm: true, to: pasteboard)
        })

        XCTAssertEqual(confirmed, "from the terminal")
        XCTAssertEqual(pasteboard.string(forType: .string), "from the terminal")
    }

    /// The point of the gate: a denied OSC 52 write leaves what the user had in place.
    @MainActor
    func testDeniedUntrustedWriteLeavesThePasteboardUntouched() {
        let pasteboard = testPasteboard()
        pasteboard.clearContents()
        pasteboard.setString("the user's own text", forType: .string)

        withApproval({ _ in false }, {
            GhosttyClipboardWrite.apply("from the terminal", confirm: true, to: pasteboard)
        })

        XCTAssertEqual(pasteboard.string(forType: .string), "the user's own text")
    }

    /// The kitty-write gate: the write policy decides, and logs, through `approves`.
    @MainActor
    func testWriteGateDecisionFollowsThePolicy() {
        var shown: String?
        var approved = false
        withApproval({ text in
            shown = text
            return true
        }, {
            approved = GhosttyClipboardWrite.approves("kitty write")
        })
        XCTAssertEqual(shown, "kitty write")
        XCTAssertTrue(approved)

        withApproval({ _ in false }, {
            approved = GhosttyClipboardWrite.approves("kitty write")
        })
        XCTAssertFalse(approved)
    }

    // MARK: - The untrusted read gate

    /// The point of the gate: a denied untrusted read is refused, so the caller denies the
    /// request and the clipboard never reaches the asking program.
    @MainActor
    func testDeniedUntrustedReadIsRefused() {
        var approved = true
        withReadApproval({ _ in false }, {
            approved = GhosttyClipboardRead.approves("TOP-SECRET-clipboard-contents")
        })

        XCTAssertFalse(approved)
    }

    /// What the prompt shows is what approving it gives away, so the user judges the actual
    /// content rather than a summary of it.
    @MainActor
    func testTheReadPromptShowsTheTextItWouldHandOver() {
        var shown: String?
        var approved = false
        withReadApproval({ text in
            shown = text
            return true
        }, {
            approved = GhosttyClipboardRead.approves("s3cret-token")
        })

        XCTAssertEqual(shown, "s3cret-token")
        XCTAssertTrue(approved)
    }

    /// A pasteboard of the test's own, so no test ever touches the developer's clipboard.
    /// A uniquely named pasteboard stays registered with the pasteboard server after the
    /// process exits, so it is released again when the test ends.
    private func testPasteboard() -> NSPasteboard {
        let name = NSPasteboard.Name("casper.tests.clipboard-write.\(UUID().uuidString)")
        // Named by its name rather than by the instance, so the teardown block carries
        // nothing across isolation boundaries.
        addTeardownBlock { NSPasteboard(name: name).releaseGlobally() }
        let pasteboard = NSPasteboard(name: name)
        pasteboard.clearContents()
        return pasteboard
    }

    /// Run `body` with `approval` standing in for the modal confirmation, restoring the
    /// production policy afterwards so one test cannot disarm the next.
    @MainActor
    private func withApproval(
        _ approval: @escaping @MainActor (String) -> Bool, _ body: () -> Void
    ) {
        let production = GhosttyClipboardWrite.approveUntrusted
        GhosttyClipboardWrite.approveUntrusted = approval
        defer { GhosttyClipboardWrite.approveUntrusted = production }
        body()
    }

    /// The read gate's counterpart to `withApproval`, restoring the production policy so one
    /// test cannot disarm the next.
    @MainActor
    private func withReadApproval(
        _ approval: @escaping @MainActor (String) -> Bool, _ body: () -> Void
    ) {
        let production = GhosttyClipboardRead.approveUntrusted
        GhosttyClipboardRead.approveUntrusted = approval
        defer { GhosttyClipboardRead.approveUntrusted = production }
        body()
    }
}
