import AppKit
import Foundation
import XCTest

@testable import CasperGhostty

final class GhosttyFocusCallbackTests: XCTestCase {
    /// Holds the host window for the duration of the test: the view only keeps a weak
    /// reference to its window, and a window released mid-test would look to the view
    /// like a detach.
    @MainActor private var hostWindow: NSWindow?

    /// A view hosted in a borderless offscreen window — the same recipe
    /// `RealSurfaceHarness` uses — so the window-key half of the focus state is
    /// exercisable.
    ///
    /// The view is invalidated before it is hosted: the `.forTesting()` runtime creates
    /// no surface, so hosting it would only spend the bounded creation retries on an
    /// attempt that cannot succeed. `debugLastFocusValue` is recorded regardless, which
    /// is what these tests read.
    @MainActor
    private func makeHostedView() -> GhosttySurfaceView {
        let view = GhosttySurfaceView(
            runtime: .forTesting(), configuration: GhosttySurfaceConfiguration())
        view.invalidate()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        hostWindow = window
        return view
    }

    /// Drive the host window's key status the only way a headless test can: by posting
    /// the notification AppKit would post. `makeKeyAndOrderFront` does not take in a test
    /// runner, which owns no key window.
    @MainActor
    private func postKeyNotification(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: hostWindow)
    }

    /// First responder in a window that is not key is *not* focused: the hollow caret a
    /// native terminal draws in an inactive window comes from libghostty's per-surface
    /// focus state, so it must be false even while this view owns the responder chain.
    @MainActor
    func testFirstResponderInNonKeyWindowRecordsFocusLost() {
        let view = makeHostedView()
        _ = view.becomeFirstResponder()
        XCTAssertEqual(view.debugLastFocusValue, false)
    }

    /// Both inputs together are what make the caret solid: the window becoming key while
    /// this view holds first responder pushes focus gained.
    @MainActor
    func testWindowBecomingKeyWhileFirstResponderRecordsFocusGained() {
        let view = makeHostedView()
        _ = view.becomeFirstResponder()
        postKeyNotification(NSWindow.didBecomeKeyNotification)
        XCTAssertEqual(view.debugLastFocusValue, true)
    }

    /// The reported bug: AppKit sends no `resignFirstResponder` when a window merely
    /// stops being key, so the resign-key notification is the only signal that can
    /// hollow the caret of the still-first-responder terminal.
    @MainActor
    func testWindowResigningKeyWhileFirstResponderRecordsFocusLost() {
        let view = makeHostedView()
        _ = view.becomeFirstResponder()
        postKeyNotification(NSWindow.didBecomeKeyNotification)
        postKeyNotification(NSWindow.didResignKeyNotification)
        XCTAssertEqual(view.debugLastFocusValue, false)
    }

    /// Resigning first responder in a key window still pushes focus lost — the responder
    /// half of the state carries on its own.
    @MainActor
    func testResigningFirstResponderInKeyWindowRecordsFocusLost() {
        let view = makeHostedView()
        _ = view.becomeFirstResponder()
        postKeyNotification(NSWindow.didBecomeKeyNotification)
        _ = view.resignFirstResponder()
        XCTAssertEqual(view.debugLastFocusValue, false)
    }

    /// `blurForLayoutChange()` pushes a "not focused" state into libghostty. The
    /// `.forTesting()` runtime creates no surface, but `debugLastFocusValue` is
    /// recorded regardless, so the intent is headlessly observable.
    @MainActor
    func testBlurForLayoutChangeRecordsFocusLost() {
        let view = makeHostedView()
        _ = view.becomeFirstResponder()
        postKeyNotification(NSWindow.didBecomeKeyNotification)
        view.blurForLayoutChange()
        XCTAssertEqual(view.debugLastFocusValue, false)
    }

    /// A view the layout coordinator blurred stays blurred: the blur clears the
    /// responder input, so the window regaining key status cannot resurrect a solid
    /// caret on a surface that is about to be reparented.
    @MainActor
    func testWindowBecomingKeyAfterLayoutBlurKeepsFocusLost() {
        let view = makeHostedView()
        _ = view.becomeFirstResponder()
        view.blurForLayoutChange()
        postKeyNotification(NSWindow.didBecomeKeyNotification)
        XCTAssertEqual(view.debugLastFocusValue, false)
    }
}
