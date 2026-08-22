import AppKit
import SwiftUI
import XCTest
@testable import CasperUI

@MainActor
final class BrowserSurfaceViewTests: XCTestCase {
    func testNormalize() {
        XCTAssertEqual(
            BrowserSurfaceView.normalize("localhost:3000")?.absoluteString,
            "http://localhost:3000")
        XCTAssertEqual(
            BrowserSurfaceView.normalize("https://x.dev")?.absoluteString,
            "https://x.dev")
        // A scheme + host + port must be honored, never double-prefixed.
        XCTAssertEqual(
            BrowserSurfaceView.normalize("http://localhost:9000")?.absoluteString,
            "http://localhost:9000")
        XCTAssertNil(BrowserSurfaceView.normalize("   "))
    }

    func testExternalURL() {
        // Prefers the committed web view URL over the address text.
        XCTAssertEqual(
            BrowserSurfaceView.externalURL(
                webViewURL: URL(string: "http://localhost:3000/app"), address: "localhost:9999"
            )?.absoluteString,
            "http://localhost:3000/app")
        // Falls back to the normalized address when there is no committed URL yet.
        XCTAssertEqual(
            BrowserSurfaceView.externalURL(webViewURL: nil, address: "localhost:3000")?.absoluteString,
            "http://localhost:3000")
        // No committed URL and no valid address (e.g. still at about:blank, empty address).
        XCTAssertNil(BrowserSurfaceView.externalURL(webViewURL: nil, address: ""))
        // A fresh surface's initial about:blank load commits in WKWebView (webView.url
        // becomes non-nil "about:blank"), but that must still count as "no URL" — not
        // an openable page — so the button stays disabled until a real navigation.
        XCTAssertNil(BrowserSurfaceView.externalURL(webViewURL: URL(string: "about:blank"), address: ""))
        // The real runtime state on a fresh surface: BrowserCoordinator.syncNav() sets
        // `address` to the committed URL's string on every commit, including the initial
        // about:blank one — so address is "about:blank" too, not empty. Lock in that the
        // button stays disabled against this actual composite state, not just the
        // empty-address case above.
        XCTAssertNil(BrowserSurfaceView.externalURL(webViewURL: .aboutBlank, address: "about:blank"))
    }

    /// Return must end editing, and must do so *before* the submitted load starts:
    /// while the field stays first responder the coordinator's `isEditingAddress`
    /// never clears, and `syncNav` then skips writing the canonical URL back into
    /// the address bar for good.
    func testReturnEndsEditingBeforeSubmitting() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 60),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let field = NSTextField()
        window.contentView?.addSubview(field)

        var events: [String] = []
        let addressField = AddressField(
            text: .constant("localhost:3000"),
            onSubmit: { events.append("submit") },
            onFocusChange: { events.append($0 ? "beginEditing" : "endEditing") })
        let coordinator = addressField.makeCoordinator()
        field.delegate = coordinator

        XCTAssertTrue(window.makeFirstResponder(field), "the field must take focus for a field editor to exist")
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView, "no field editor")
        // `controlTextDidBeginEditing` only posts for a key window, which a headless
        // test has none of; seed the state the app is in when the user types.
        coordinator.isEditing = true

        let handled = coordinator.control(
            field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        XCTAssertTrue(handled, "Return must be consumed instead of inserting a newline")
        XCTAssertEqual(
            Array(events.suffix(2)), ["endEditing", "submit"],
            "editing must end before the submitted load starts")
        XCTAssertFalse(coordinator.isEditing)
        XCTAssertFalse(window.firstResponder === editor, "the field editor must have resigned first responder")
    }
}
