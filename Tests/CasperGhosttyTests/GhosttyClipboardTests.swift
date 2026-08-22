import AppKit
import GhosttyKit
import XCTest

@testable import CasperGhostty

final class GhosttyClipboardTests: XCTestCase {
    func testReadsDataFromFirstContent() {
        "hello".withCString { data in
            "text/plain".withCString { mime in
                var content = ghostty_clipboard_content_s(mime: mime, data: data)
                withUnsafePointer(to: &content) { ptr in
                    XCTAssertEqual(clipboardString(from: ptr, count: 1), "hello")
                }
            }
        }
    }

    func testNilContentIsNil() {
        XCTAssertNil(clipboardString(from: nil, count: 0))
    }

    // MARK: - What libghostty is configured to ask about

    /// The write gate only runs if libghostty is told to ask: `clipboard-write = ask` is what
    /// raises the `confirm` flag on the write callback (libghostty's own default is `allow`).
    /// Every gate test below passes with or without that line, because they drive the approval
    /// seam directly — which is exactly how a gate once shipped unreachable, green tests and
    /// all. Deleting the config line must fail here.
    func testDefaultConfigMakesLibghosttyAskBeforeAnUntrustedWrite() {
        XCTAssertTrue(
            GhosttyDefaultConfig.text.contains("clipboard-write = ask"),
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

    // MARK: - The OSC 52 read gate

    /// An approved OSC 52 read answers with the clipboard text the terminal asked for.
    @MainActor
    func testApprovedUntrustedReadHandsBackTheClipboardText() {
        var answer = ""
        withReadApproval({ _ in true }, {
            answer = GhosttyClipboardRead.resolveUntrusted("the user's own text")
        })

        XCTAssertEqual(answer, "the user's own text")
    }

    /// The point of the gate: a denied OSC 52 read tells the terminal nothing about the
    /// clipboard, and still answers — an unanswered read leaves the asking program waiting.
    @MainActor
    func testDeniedUntrustedReadHandsBackNothing() {
        var answer = "not an answer yet"
        withReadApproval({ _ in false }, {
            answer = GhosttyClipboardRead.resolveUntrusted("TOP-SECRET-clipboard-contents")
        })

        XCTAssertEqual(answer, "")
    }

    /// What the prompt shows is what approving it gives away, so the user judges the actual
    /// content rather than a summary of it.
    @MainActor
    func testTheReadPromptShowsTheTextItWouldHandOver() {
        var shown: String?
        var answer = ""
        withReadApproval({ text in
            shown = text
            return true
        }, {
            answer = GhosttyClipboardRead.resolveUntrusted("s3cret-token")
        })

        XCTAssertEqual(shown, "s3cret-token")
        XCTAssertEqual(answer, shown)
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
