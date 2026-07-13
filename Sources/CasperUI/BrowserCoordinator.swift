import CasperCore
import Combine
import WebKit

/// Owns a browser surface's `WKWebView` and its navigation state, kept alive in
/// `AppModel`'s cache so it survives layout restructuring. Reports focus and
/// commits (URL, back/forward availability) back to the model/UI. One per
/// browser `Surface.id`.
@MainActor
final class BrowserCoordinator: NSObject, ObservableObject, WKNavigationDelegate {
    let surfaceID: UUID
    let webView: WKWebView
    @Published var address: String = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    /// The last navigation failure, surfaced as a banner and cleared when a new
    /// navigation starts. Nil while the current load is healthy.
    @Published var loadError: String?

    /// True while the user is editing the address field. A navigation that
    /// finishes mid-edit must not overwrite their in-progress text, so `syncNav`
    /// skips the `address` assignment while this is set. Driven by the view's
    /// focus state; not `@Published` since only the view mutates it.
    var isEditingAddress = false

    /// Called with the committed URL so the model persists it into the surface.
    var onCommitURL: ((URL) -> Void)?
    /// Called when the web view gains first-responder, to update focus.
    var onFocus: (() -> Void)?

    init(surfaceID: UUID, url: URL) {
        self.surfaceID = surfaceID
        let web = FocusReportingWebView(frame: .zero)
        self.webView = web
        super.init()
        web.onFocus = { [weak self] in self?.onFocus?() }
        web.navigationDelegate = self
        self.address = url == .aboutBlank ? "" : url.absoluteString
        web.load(URLRequest(url: url))
    }

    /// Load a user-entered address (already normalized to a URL).
    func load(_ url: URL) { webView.load(URLRequest(url: url)) }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }

    private func syncNav() {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        // about:blank is the initial placeholder load (see `init`), not a committed
        // URL: never surface it as text or persist it, so a never-navigated surface
        // keeps its empty address (which shows the placeholder).
        if let url = webView.url, url != .aboutBlank {
            // Persist the committed URL regardless, but leave the visible text
            // alone while the user is mid-edit so their typing isn't clobbered.
            if !isEditingAddress { address = url.absoluteString }
            onCommitURL?(url)
        }
    }

    private func handleFailure(_ error: Error) {
        // A load superseded by a newer one reports as cancelled — not a failure.
        let nsError = error as NSError
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else { return }
        loadError = error.localizedDescription
        syncNav()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loadError = nil
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { syncNav() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { syncNav() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleFailure(error)
    }
    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
    ) {
        handleFailure(error)
    }
}

/// A `WKWebView` that reports first-responder acquisition, so clicking into web
/// content updates the focused surface (parallels `GhosttySurfaceView`).
final class FocusReportingWebView: WKWebView {
    var onFocus: (() -> Void)?

    // The occlusion observer for the current window, and the last suspension
    // value pushed to WebKit (so a repeat state is not re-pushed). `lastSuspended`
    // starts nil: a fresh web view plays media, so the first push always lands.
    // `nonisolated(unsafe)` on `occlusionObserver` is safe here: it's only ever
    // mutated from `updateOcclusionObserver()` on the main actor, and by the time
    // `deinit` runs no other reference to the object exists, so there's no
    // concurrent access to race with (and `NotificationCenter.removeObserver` is
    // itself thread-safe). This lets `deinit` read it without a main-actor hop —
    // avoiding the `isolated deinit` back-deployment shim that SIGABRTs on the CI
    // runner (see the isolated-deinit-ci-sigabrt project memory note).
    nonisolated(unsafe) private var occlusionObserver: NSObjectProtocol?
    private var lastSuspended: Bool?

    override func becomeFirstResponder() -> Bool {
        onFocus?()
        return super.becomeFirstResponder()
    }

    /// Suppress WebKit's native context menu so Casper's pane menu is the only
    /// menu offered on a browser pane. WebKit builds this menu asynchronously,
    /// so emptying it here is the supported hook.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        menu.removeAllItems()
    }

    deinit {
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
        }
    }

    // MARK: Media suspension (perf: pause audio/video for an off-screen web view)

    // A detached or occluded cached browser keeps decoding media off-screen, so
    // suspend playback when it isn't visible. macOS exposes no public API to
    // throttle a detached web view's JS timers / requestAnimationFrame — only
    // media suspension — so this is a media-only partial fix. Mirrors the
    // occlusion wiring in `GhosttySurfaceView`.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateOcclusionObserver()
        refreshMediaSuspension()
    }

    // Recompute suspension from window membership + the window's live occlusion
    // state. No window ⇒ the view is a detached cached surface (fully off-screen).
    // Minimize / cover / off-Space all clear `.visible`.
    private func refreshMediaSuspension() {
        guard let window else { pushMediaSuspension(true); return }
        pushMediaSuspension(!window.occlusionState.contains(.visible))
    }

    // Single point that pushes suspension into WebKit, de-duplicated so a repeat
    // state is not re-pushed. Records the value for DEBUG tests.
    private func pushMediaSuspension(_ suspended: Bool) {
        guard lastSuspended != suspended else { return }
        lastSuspended = suspended
        setAllMediaPlaybackSuspended(suspended, completionHandler: nil)
        #if DEBUG
        debugLastMediaSuspended = suspended
        #endif
    }

    // (Re)subscribe to the current window's occlusion notifications; unsubscribe
    // when leaving a window. Called from `viewDidMoveToWindow`.
    private func updateOcclusionObserver() {
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        guard let window else { return }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMediaSuspension() }
        }
    }

    #if DEBUG
    // Test seam: records the last suspension value `pushMediaSuspension` sent to
    // WebKit, which is set-only and exposes no getter to read back. Lets a unit
    // test assert a detached view suspends without a live window. Stays nil until
    // the first transition.
    private(set) var debugLastMediaSuspended: Bool?

    func debugRefreshMediaSuspension() { refreshMediaSuspension() }
    #endif
}
