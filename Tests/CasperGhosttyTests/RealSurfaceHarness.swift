import AppKit
import XCTest
import CasperTestSupport

@testable import CasperGhostty

/// Shared bring-up for the real-surface end-to-end tests: a real `GhosttyRuntime`, a
/// real (offscreen) `NSWindow` and a live PTY-backed shell — the recipe the
/// `ghostty-real-surface-e2e-harness` memory note describes. The `.forTesting()`
/// runtime never creates a surface, so none of this class of behavior is reachable
/// without it.
extension XCTestCase {
    /// Bring up a live surface, hand it to `body`, and tear it down afterwards.
    ///
    /// `makeView` builds the view under test, so a caller can supply its own
    /// configuration, surface id or callbacks. The view is made first responder before
    /// `body` runs, matching how a real terminal receives keystrokes, and the run loop is
    /// pumped until the shell is interactively ready (see `settle(_:)`), so `body` can type
    /// at it straight away.
    ///
    /// Throws `XCTSkip` when libghostty cannot produce a surface in this environment — a
    /// documented flakiness (see the `e2e-surface-creation-flakiness` note), so the
    /// precondition is unmet rather than the behavior broken.
    @MainActor
    func withRealSurface(
        makeView: (GhosttyRuntime) -> GhosttySurfaceView,
        body: (GhosttySurfaceView, GhosttySurface) throws -> Void
    ) throws {
        let runtime = try makeIsolatedRuntime()
        let view = makeView(runtime)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view  // triggers viewDidMoveToWindow -> ghostty_surface_new

        // Free the surface while the view is still fully alive: libghostty can emit an
        // action from inside the free, and the trampolines recover the view with
        // `takeUnretainedValue()` — see the `surface-view-invalidate-before-release`
        // note. Dropping the view from the window without this leaves the shell running
        // on an orphaned PTY for the rest of the test process.
        defer {
            view.invalidate()
            window.contentView = nil
        }

        // Surface creation can transiently return null and retry; poll until it lands. The
        // view tries at once and then at most twice more, 0.25 s apart
        // (`GhosttySurfaceView.maxSurfaceCreationAttempts`), before giving up until its next
        // window entry, so polling past ~0.5 s would only delay the skip.
        let deadline = Date().addingTimeInterval(1)
        while view.surface == nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        guard let surface = view.surface else {
            throw XCTSkip("libghostty could not create a surface in this environment")
        }
        XCTAssertTrue(window.makeFirstResponder(view))
        // Fixed, not polled: an under-settled shell reads back kernel cooked-mode echo
        // instead of real line-editor behaviour (see the harness note).
        settle(0.6)

        try body(view, surface)
    }

    /// `withRealSurface` for a plain view — the common case.
    @MainActor
    func withRealSurface(body: (GhosttySurfaceView, GhosttySurface) throws -> Void) throws {
        try withRealSurface(
            makeView: { GhosttySurfaceView(runtime: $0, configuration: GhosttySurfaceConfiguration()) },
            body: body)
    }

    /// A real `GhosttyRuntime` that reads none of the developer's own Ghostty config and
    /// writes its theme files to `themeDirectory`, a per-test temporary directory unless
    /// the caller passes the one it inspects. A local `clipboard-read = allow` or a rebound
    /// `super+n` would otherwise change what a test observes; CI has no user config, so
    /// such a leak would only bite local runs.
    func makeIsolatedRuntime(themeDirectory: URL? = nil) throws -> GhosttyRuntime {
        try GhosttyRuntime(
            themeDirectory: themeDirectory ?? makeTemporaryDirectory(prefix: "casper-ghostty-themes"),
            loadUserFiles: { _ in })
    }

    /// Pump the main run loop for a fixed duration so libghostty can drain PTY output and
    /// the shell can settle. A stability-polling loop was flaky here; a fixed pump is
    /// enough.
    @MainActor
    func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
