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

    /// The URL to re-issue after a failed navigation (nothing committed, so
    /// `webView.reload()` would no-op). Nil while the load is healthy.
    private var failedURL: URL?

    /// True while the user is editing the address field. A navigation that
    /// finishes mid-edit must not overwrite their in-progress text, so `syncNav`
    /// skips the `address` assignment while this is set. Driven by the view's
    /// focus state; not `@Published` since only the view mutates it.
    var isEditingAddress = false

    /// Called with the committed URL so the model persists it into the surface.
    var onCommitURL: ((URL) -> Void)?
    /// Called when the web view gains first-responder, to update focus.
    var onFocus: (() -> Void)?

    /// Bounded ring buffer (cap `consoleBufferCapacity`, oldest dropped) of the
    /// page's captured `console.*` calls and uncaught errors/rejections, oldest
    /// first. Fed by the injected user script via the `casperConsole` handler and
    /// drained by `browser console`.
    private var consoleBuffer: [ConsoleEntry] = []
    private static let consoleBufferCapacity = 500

    init(surfaceID: UUID, url: URL) {
        self.surfaceID = surfaceID
        // Build a configuration that captures the page's console output and uncaught
        // errors: a document-start user script wraps `console.*`, `window.onerror`,
        // and `unhandledrejection`, forwarding each entry to the `casperConsole`
        // message handler. `WeakScriptMessageHandler` forwards weakly so the
        // controller→handler→coordinator chain never forms a retain cycle: the
        // controller strongly retains the handler, but the handler holds the
        // coordinator weakly, so nothing points back to keep it alive.
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(
            source: Self.consoleCaptureScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let messageHandler = WeakScriptMessageHandler()
        controller.add(messageHandler, name: "casperConsole")
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        let web = FocusReportingWebView(frame: .zero, configuration: config)
        self.webView = web
        super.init()
        messageHandler.coordinator = self
        web.onFocus = { [weak self] in self?.onFocus?() }
        web.navigationDelegate = self
        self.address = url == .aboutBlank ? "" : url.absoluteString
        web.load(URLRequest(url: url))
    }

    /// Load a user-entered address (already normalized to a URL).
    func load(_ url: URL) { webView.load(URLRequest(url: url)) }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    func reload() {
        // WKWebView.reload() reloads the *committed* page. After a failed provisional
        // navigation nothing committed (webView.url is nil, back/forward list empty),
        // so reload() is a silent no-op — re-issue the failed request instead so a
        // now-reachable server actually loads. The address-bar Return path already
        // works because it always issues a fresh load().
        if let failedURL {
            webView.load(URLRequest(url: failedURL))
        } else {
            webView.reload()
        }
    }

    /// The URL that failed to load, extracted from a navigation error's userInfo.
    /// Returns nil when the error carries no failing URL.
    static func failingURL(from error: Error) -> URL? {
        let userInfo = (error as NSError).userInfo
        if let url = userInfo[NSURLErrorFailingURLErrorKey] as? URL { return url }
        if let string = userInfo[NSURLErrorFailingURLStringErrorKey] as? String { return URL(string: string) }
        return nil
    }

    #if DEBUG
    /// Test seam: the URL a reload would re-issue (nil ⇒ reload() falls through to
    /// the live page). Lets a unit test assert the failed-state reload path without
    /// a live page/server.
    var debugReloadTarget: URL? { failedURL }
    #endif

    // MARK: - Automation (release control channel)

    /// Evaluate `js` in the page and return its result serialized to a JSON
    /// string (`.fragmentsAllowed`, so scalars come back as `2`, `"hi"`, `true`);
    /// `undefined`/`null`, and non-JSON-serializable results (`NaN`/`Infinity`),
    /// become `"null"`. A JS runtime error is rethrown as a
    /// `BrowserCoordinatorError` carrying the page's exception message.
    func evaluate(_ js: String) async throws -> String {
        // Serialize the result to a JSON String (Sendable) inside the completion
        // handler: the raw `Any?` is main-actor-isolated and not Sendable, so it
        // can't cross the continuation boundary directly.
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(js) { result, error in
                if let error {
                    continuation.resume(throwing: BrowserCoordinatorError(message: Self.message(from: error)))
                } else {
                    continuation.resume(returning: Self.jsonString(from: result))
                }
            }
        }
    }

    // MARK: - Console capture

    /// Ingest one `casperConsole` message body (a JS object) into the buffer. Called
    /// from `WeakScriptMessageHandler` on the main actor. A malformed body (missing
    /// the required keys) is ignored rather than surfaced.
    func ingestConsoleMessage(_ body: Any) {
        guard let dict = body as? [String: Any] else { return }
        let entry = ConsoleEntry(
            level: dict["level"] as? String ?? "log",
            message: dict["message"] as? String ?? "",
            timestamp: (dict["timestamp"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 * 1000,
            source: dict["source"] as? String,
            line: (dict["line"] as? NSNumber)?.intValue,
            column: (dict["column"] as? NSNumber)?.intValue,
            stack: dict["stack"] as? String)
        appendConsole(entry)
    }

    /// Append one entry, evicting the oldest once the buffer exceeds its cap.
    private func appendConsole(_ entry: ConsoleEntry) {
        consoleBuffer.append(entry)
        if consoleBuffer.count > Self.consoleBufferCapacity {
            consoleBuffer.removeFirst(consoleBuffer.count - Self.consoleBufferCapacity)
        }
    }

    /// Return the buffered console entries oldest→newest. `level` keeps only
    /// entries at or above that severity threshold; `clear` drains the ENTIRE
    /// buffer afterwards (an unconditional drain, never filtered — a partial clear
    /// would be surprising).
    func consoleSnapshot(level: ConsoleLevel?, clear: Bool) -> [ConsoleEntry] {
        let snapshot: [ConsoleEntry]
        if let level {
            snapshot = consoleBuffer.filter { (ConsoleLevel(rawValue: $0.level) ?? .log) >= level }
        } else {
            snapshot = consoleBuffer
        }
        if clear { consoleBuffer.removeAll() }
        return snapshot
    }

    #if DEBUG
    /// Test seam: feed the buffer directly, without a live page posting messages,
    /// so the ring-buffer/threshold/drain behaviour is unit-testable. Mirrors the
    /// `debugLastMediaSuspended` seam on `FocusReportingWebView`.
    func debugAppendConsole(_ entry: ConsoleEntry) { appendConsole(entry) }
    #endif

    // MARK: - Wait

    /// Poll `predicate` (a JS boolean expression) roughly every 100 ms until it is
    /// truthy or `timeoutMs` elapses; return whether it became true. The predicate
    /// is evaluated as `!!(predicate)`, so a predicate that throws counts as
    /// not-yet-true and polling continues (a malformed predicate thus surfaces as a
    /// timeout). Sleeps asynchronously between polls, so the main actor is never
    /// blocked while waiting.
    func waitFor(js predicate: String, timeoutMs: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while true {
            if await evaluatePredicate(predicate) { return true }
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Evaluate `!!(predicate)` once; a JS error or a non-boolean result is treated
    /// as `false` (not yet true).
    private func evaluatePredicate(_ predicate: String) async -> Bool {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript("!!(\(predicate))") { result, error in
                continuation.resume(returning: error == nil && (result as? Bool ?? false))
            }
        }
    }

    /// Render the current page to a PNG. A cached, unmounted surface has no window
    /// (a detached view), which would snapshot to an empty image; give it a default
    /// 1280x800 frame first so the capture has real content to render. Gated
    /// strictly on `window == nil` — a zero-bounds mounted view is a transient
    /// layout pass (the inspector reveal animation), and resizing it there would
    /// race SwiftUI; a mounted view keeps its live panel size. Sized/URL-overridden
    /// captures don't route through here — they use the dedicated off-screen
    /// `BrowserCapture` instead.
    func snapshot() async throws -> Data {
        if webView.window == nil {
            webView.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        }
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

    /// Serialize an `evaluateJavaScript` result to a JSON string. `nil`/`NSNull`
    /// (the JS `undefined`/`null`) become `"null"`.
    private static func jsonString(from value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "null" }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let string = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return string
    }

    /// Extract a clean message from a WebKit JS error, preferring the page's own
    /// exception text over the generic `NSError` description.
    private static func message(from error: Error) -> String {
        let nsError = error as NSError
        if let message = nsError.userInfo["WKJavaScriptExceptionMessage"] as? String, !message.isEmpty {
            return message
        }
        return nsError.localizedDescription
    }

    /// Injected at document start: wraps every `console.*` method and adds `error`
    /// + `unhandledrejection` listeners, forwarding each entry to the
    /// `casperConsole` message handler. Error capture uses
    /// `addEventListener("error", …)` rather than assigning `window.onerror`, so it
    /// neither clobbers a handler the page already set nor gets silently replaced
    /// when the page later installs its own (as error-tracking SDKs do) — and it
    /// additionally catches resource-load errors. Arguments are stringified
    /// defensively (`JSON.stringify` under try/catch, falling back to `String(arg)`,
    /// which also preserves `undefined`/functions that `JSON.stringify` drops) and
    /// joined with a space, so a circular or exotic argument can never break
    /// capture. The original `console.*` methods are still called, so DevTools
    /// output is unaffected.
    private static let consoleCaptureScript = """
    (function () {
      function post(entry) {
        try { window.webkit.messageHandlers.casperConsole.postMessage(entry); } catch (e) {}
      }
      function stringify(arg) {
        if (typeof arg === "string") { return arg; }
        var json;
        try { json = JSON.stringify(arg); } catch (e) { return String(arg); }
        // JSON.stringify returns undefined for undefined/functions/symbols; fall
        // back to String(arg) so those still render (e.g. "undefined") instead of "".
        return typeof json === "undefined" ? String(arg) : json;
      }
      function format(args) {
        return Array.prototype.map.call(args, stringify).join(" ");
      }
      ["debug", "log", "info", "warn", "error"].forEach(function (level) {
        var original = console[level];
        console[level] = function () {
          post({ level: level, message: format(arguments), timestamp: Date.now() });
          if (original) { original.apply(console, arguments); }
        };
      });
      window.addEventListener("error", function (event) {
        post({
          level: "error",
          message: event.message ? String(event.message) : "uncaught error",
          timestamp: Date.now(),
          source: event.filename,
          line: event.lineno,
          column: event.colno,
          stack: event.error && event.error.stack ? String(event.error.stack) : undefined
        });
      });
      window.addEventListener("unhandledrejection", function (event) {
        var reason = event.reason;
        post({
          level: "error",
          message: reason && reason.message ? String(reason.message) : String(reason),
          timestamp: Date.now(),
          stack: reason && reason.stack ? String(reason.stack) : undefined
        });
      });
    })();
    """

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
        failedURL = Self.failingURL(from: error)
        loadError = error.localizedDescription
        syncNav()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loadError = nil
        failedURL = nil
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

/// Error carrying a human-readable reason for a failed browser-automation op
/// (a JS runtime error or a snapshot/encoding failure).
struct BrowserCoordinatorError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// Forwards `WKScriptMessage` bodies to a `BrowserCoordinator` through a *weak*
/// reference. `WKUserContentController` retains its message handlers strongly, so
/// registering the coordinator itself would form a
/// coordinator→webView→config→controller→handler→coordinator retain cycle. This
/// thin proxy breaks it: the controller retains the proxy, the proxy holds the
/// coordinator weakly. `WKScriptMessageHandler` is `@MainActor` in the SDK, so the
/// callback (and the forwarded `ingestConsoleMessage`) run on the main actor.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var coordinator: BrowserCoordinator?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        coordinator?.ingestConsoleMessage(message.body)
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
