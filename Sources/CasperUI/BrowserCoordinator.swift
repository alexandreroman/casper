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
        if let url = webView.url {
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
}
