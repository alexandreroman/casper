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
    /// After navigation finishes, how long to wait for the page to fully render
    /// before snapshotting anyway. This bounds the network-bound part of the wait —
    /// web fonts and deferred images, which can take seconds on a slow origin — since
    /// `waitForFullRender` caps the paint barrier itself with its own short fallback.
    /// Best-effort: the load already succeeded, so a stalled resource should
    /// still yield a snapshot rather than fail the capture.
    private static let renderSettleTimeout: Duration = .seconds(5)

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

        // A WKWebView never placed in a window may not lay out or paint, so host it in
        // a borderless window — one deliberately never ordered on-screen. Layout and
        // painting only need a non-nil `window`, whereas an ordered window parked at
        // -100_000 joins Mission Control's layout: its bounding box then spans ~101,000
        // px and every real window is scaled to nothing. The window and delegate are
        // held in locals so they outlive the awaits (WKWebView retains its navigation
        // delegate only weakly), and torn down in `defer` even on throw.
        let window = NSWindow(
            contentRect: NSRect(x: -100_000, y: -100_000, width: CGFloat(width), height: CGFloat(height)),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = webView

        let delegate = NavigationLoadDelegate(url: url)
        webView.navigationDelegate = delegate

        defer {
            webView.navigationDelegate = nil
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

        // `didFinish` fires on the main frame's load event, but pages routinely
        // paint after it — fonts swap in, images finish decoding, SPA frameworks
        // hydrate on the next tick. A fixed delay just guesses at that; instead
        // wait for the real readiness signals (bounded and best-effort).
        await waitForFullRender(of: webView)

        return try await snapshotPNG(of: webView)
    }

    /// Render `webView`'s current contents to a PNG at the display's backing scale.
    /// Shared by the off-screen capture above and the live panel's
    /// `BrowserCoordinator.snapshot()`; the caller owns any frame/readiness setup.
    static func snapshotPNG(of webView: WKWebView) async throws -> Data {
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

    /// Wait until the loaded page has settled visually: DOM complete, web fonts
    /// ready, in-flight images finished (load or error), then a paint barrier of two
    /// animation frames raced against a ~120 ms fallback. The race is required, not a
    /// safety net: `requestAnimationFrame` never fires in a window parked off any
    /// display (see the -100_000 placement above), so the barrier alone would never
    /// resolve and every capture would burn the full `renderSettleTimeout`. A visible
    /// window still waits for a real compositor paint; an off-display one proceeds
    /// after roughly two frames' worth of slack. Bounded by `renderSettleTimeout` and
    /// fully best-effort — any error or timeout just proceeds to the snapshot.
    private static func waitForFullRender(of webView: WKWebView) async {
        let js = """
        await new Promise((resolve) => {
          const settle = () => {
            const pending = Array.from(document.images)
              .filter((img) => !img.complete)
              .map((img) => new Promise((done) => {
                img.addEventListener('load', done, { once: true });
                img.addEventListener('error', done, { once: true });
              }));
            const fonts = (document.fonts && document.fonts.ready) || Promise.resolve();
            Promise.all([fonts, ...pending]).then(() => {
              const painted = new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
              const slack = new Promise((r) => setTimeout(r, 120));
              Promise.race([painted, slack]).then(resolve);
            });
          };
          if (document.readyState === 'complete') settle();
          else window.addEventListener('load', settle, { once: true });
        });
        """

        // Race the readiness JS against the timeout with a one-shot resume guard.
        // `callAsyncJavaScript`'s bridge ignores cancellation, so the timeout must
        // resume the waiter directly rather than by cancelling the JS task — which
        // is therefore left unreferenced, to finish (or not) on its own. Whichever
        // fires first wins; the other resume is a no-op. Best-effort — a thrown JS
        // error or the timeout both simply proceed to the snapshot.
        let waiter = RenderWaiter()
        Task { @MainActor in
            _ = try? await webView.callAsyncJavaScript(
                js, arguments: [:], in: nil, contentWorld: .page)
            waiter.resume()
        }
        let timeout = Task { @MainActor in
            try? await Task.sleep(for: renderSettleTimeout)
            waiter.resume()
        }
        await waiter.wait()
        timeout.cancel()
    }
}

/// A one-shot main-actor waiter: `wait()` suspends until the first `resume()`.
/// Handles `resume()` arriving before `wait()`. Used to race the render-readiness
/// JavaScript against its timeout in `BrowserCapture.waitForFullRender`.
@MainActor
private final class RenderWaiter {
    private var continuation: CheckedContinuation<Void, Never>?
    private var resumed = false

    func wait() async {
        await withCheckedContinuation { continuation in
            if resumed {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }
    }

    func resume() {
        guard !resumed else { return }
        resumed = true
        continuation?.resume()
        continuation = nil
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
