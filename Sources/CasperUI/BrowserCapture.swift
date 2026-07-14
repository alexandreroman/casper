import AppKit
import WebKit

/// A one-shot, off-screen web-view capturer. Loads a URL in a dedicated
/// `WKWebView` sized to an arbitrary viewport and renders it to a PNG, entirely
/// independent of the workspace's live browser panel. Used by
/// `casper browser screenshot` whenever `--width/--height/--url` requests a
/// specific viewport (mobile, wide, …) so responsive breakpoints render faithfully
/// regardless of the panel's actual size (or whether it's even mounted).
@MainActor
enum BrowserCapture {
    /// How long to wait for the page's navigation to finish before giving up. Kept
    /// under the 15 s automation socket timeout so the CLI still gets a reply.
    private static let loadTimeout: Duration = .seconds(10)
    /// A short settle after `didFinish` for final layout/paint before snapshotting.
    private static let settleDelay: Duration = .milliseconds(150)

    /// Render `url` off-screen at `width`×`height` and return a PNG of the resulting
    /// viewport. The capture shares the default website data store
    /// (cookies/localStorage) with the live browser so authenticated pages render.
    /// Throws `BrowserCoordinatorError` on a load failure, timeout, or render/encode
    /// failure. The PNG is at the display's backing scale, matching the live
    /// `BrowserCoordinator.snapshot` path.
    static func snapshot(url: URL, width: Int, height: Int) async throws -> Data {
        let frame = NSRect(x: 0, y: 0, width: width, height: height)

        // Plain configuration, but sharing the default data store so cookies and
        // localStorage match the live browser. No console user-script — a capture
        // doesn't need it.
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: frame, configuration: config)

        // A WKWebView never placed in a window may not lay out or paint, so host it
        // in a borderless window parked far off-screen. The window and delegate are
        // held in locals so they outlive the awaits (WKWebView retains its
        // navigation delegate only weakly), and torn down in `defer` even on throw.
        let window = NSWindow(
            contentRect: NSRect(x: -100_000, y: -100_000, width: CGFloat(width), height: CGFloat(height)),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = webView
        window.orderFrontRegardless()

        let delegate = NavigationLoadDelegate(url: url)
        webView.navigationDelegate = delegate

        defer {
            webView.navigationDelegate = nil
            window.orderOut(nil)
            window.contentView = nil
        }

        webView.load(URLRequest(url: url))

        // Race the navigation against a timeout: whichever resolves first wins. The
        // timeout resumes the delegate's continuation with a failure; the delegate
        // guards against a double-resume, and cancelling the task here stops the
        // sleep once the load has settled.
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(for: loadTimeout)
            guard !Task.isCancelled else { return }
            delegate.fail(message: "timed out loading \(url.absoluteString) for capture")
        }
        defer { timeoutTask.cancel() }
        try await delegate.waitForLoad()

        try? await Task.sleep(for: settleDelay)

        let image = try await webView.takeSnapshot(configuration: WKSnapshotConfiguration())
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw BrowserCoordinatorError(message: "failed to render page snapshot")
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        bitmap.size = image.size
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw BrowserCoordinatorError(message: "failed to encode snapshot as PNG")
        }
        return png
    }
}

/// Bridges a `WKWebView`'s navigation completion to an `async` waiter. Resumes its
/// continuation exactly once — on `didFinish` (success), `didFail` /
/// `didFailProvisionalNavigation` (a clear load error), or `fail(message:)` (the
/// timeout). `WKNavigationDelegate` is already `@MainActor`, so the callbacks and
/// the continuation are main-actor-isolated with no data race.
@MainActor
private final class NavigationLoadDelegate: NSObject, WKNavigationDelegate {
    private let url: URL
    private var continuation: CheckedContinuation<Void, Error>?
    private var settled = false

    init(url: URL) { self.url = url }

    /// Suspend until the page's navigation settles (success, load failure, or
    /// timeout via `fail(message:)`).
    func waitForLoad() async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    /// Resume the waiter with a failure — used by the timeout.
    func fail(message: String) {
        settle(.failure(BrowserCoordinatorError(message: message)))
    }

    private func settle(_ result: Result<Void, Error>) {
        guard !settled else { return }
        settled = true
        continuation?.resume(with: result)
        continuation = nil
    }

    private func loadFailure(_ error: Error) {
        settle(.failure(BrowserCoordinatorError(
            message: "failed to load \(url.absoluteString) for capture: \(error.localizedDescription)")))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        settle(.success(()))
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadFailure(error)
    }
    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
    ) {
        loadFailure(error)
    }
}
