import CasperCore
import Foundation

/// Error carrying a human-readable reason for a failed `browser` automation op —
/// a JS runtime error, a snapshot/encode failure, an unwritable path, a timeout.
/// Thrown by `BrowserCoordinator` and `BrowserCapture` as well, so the reason a
/// verb failed reaches the CLI without being stringified through a second type.
struct BrowserOpError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// The browser-automation half of the release control channel: every
/// `casper browser <verb>` op that drives an already-existing browser surface
/// (screenshot, eval, content, url, click, scroll, type, key, console, wait,
/// reload).
///
/// Deliberately knows nothing about `AppModel`: the two things it needs — resolving
/// a workspace by id and getting-or-creating a surface's `BrowserCoordinator` — are
/// injected as closures, the same test-seam idiom `AppModel` uses for
/// `makeWorktreeWatcher` / `deliverNotification` / `gitReprobe`. The ops that mutate
/// the model (`open`/`load`/`close`) stay in `AppModel`.
@MainActor
final class BrowserAutomationController {
    private let resolveWorkspace: (UUID) -> Workspace?
    private let coordinator: (Surface) -> BrowserCoordinator?

    /// - Parameters:
    ///   - resolveWorkspace: Look up a workspace by id; nil when it no longer exists.
    ///   - coordinator: Get-or-create the persistent `BrowserCoordinator` for a
    ///     browser surface; nil for a non-browser surface.
    init(
        resolveWorkspace: @escaping (UUID) -> Workspace?,
        coordinator: @escaping (Surface) -> BrowserCoordinator?
    ) {
        self.resolveWorkspace = resolveWorkspace
        self.coordinator = coordinator
    }

    /// The get-or-create `BrowserCoordinator` for a workspace's inspector browser
    /// surface. Reuses the same cache the panel UI uses, so automation drives the
    /// live web view and works even when the panel was never shown. Nil when the
    /// workspace can't be resolved.
    private func inspectorBrowserCoordinator(in workspaceID: UUID) -> BrowserCoordinator? {
        guard let ws = resolveWorkspace(workspaceID) else { return nil }
        return coordinator(ws.inspector.browser)
    }

    /// Resolve the workspace's browser coordinator, run `body` against it, and map
    /// the outcome to a `Result`. Shared by every `controlBrowser*` op so each one
    /// stays a single expressive line. `body` returns the op's payload: the eval
    /// result, the page HTML, the screenshot path, or an empty string for the
    /// action verbs.
    private func withBrowserCoordinator(
        _ workspaceID: UUID, _ body: (BrowserCoordinator) async throws -> String
    ) async -> Result<String, BrowserOpError> {
        guard let coordinator = inspectorBrowserCoordinator(in: workspaceID) else {
            return .failure(BrowserOpError(message: "workspace not found"))
        }
        do {
            return .success(try await body(coordinator))
        } catch {
            return .failure(error as? BrowserOpError ?? BrowserOpError(message: "\(error)"))
        }
    }

    /// Snapshot the browser page to a PNG at `path`. Returns the path on success.
    ///
    /// With no `width`/`height`/`url` override this captures the live browser panel
    /// exactly as before (panel size when mounted, the 1280x800 fallback when
    /// detached). Any override switches to the dedicated off-screen `BrowserCapture`,
    /// which renders the target URL at the requested viewport (default 1280x800)
    /// independent of the panel: the `url` override if given, else the live browser's
    /// committed URL, else the surface's persisted URL — failing when none resolves.
    func controlBrowserScreenshot(
        in workspaceID: UUID, to path: String, width: Int? = nil, height: Int? = nil, url: String? = nil
    ) async -> Result<String, BrowserOpError> {
        if width == nil, height == nil, url == nil {
            return await withBrowserCoordinator(workspaceID) { coordinator in
                let png = try await coordinator.snapshot()
                try Self.writeScreenshot(png, to: path)
                return path
            }
        }
        guard let ws = resolveWorkspace(workspaceID) else {
            return .failure(BrowserOpError(message: "workspace not found"))
        }
        guard let target = resolveScreenshotURL(for: ws, override: url) else {
            return .failure(BrowserOpError(message: "no page to capture; open a page or pass --url"))
        }
        do {
            let png = try await BrowserCapture.snapshot(url: target, width: width ?? 1280, height: height ?? 800)
            try Self.writeScreenshot(png, to: path)
            return .success(path)
        } catch {
            return .failure(error as? BrowserOpError ?? BrowserOpError(message: "\(error)"))
        }
    }

    /// Resolve the page for an off-screen sized capture: the explicit `--url`
    /// override (must be absolute), else the live browser's committed URL, else the
    /// surface's persisted URL. Returns nil when nothing usable resolves (a browser
    /// that never navigated / sits on about:blank, with no override).
    private func resolveScreenshotURL(for ws: Workspace, override: String?) -> URL? {
        // A scheme is enough here (the CLI enforces scheme+host for user URLs); this
        // also admits the schemed-but-hostless `data:` URLs automation relies on.
        if let override, let parsed = URL(string: override), parsed.scheme != nil, parsed != .aboutBlank {
            return parsed
        }
        if let coordinator = coordinator(ws.inspector.browser),
           let live = coordinator.webView.url, live != .aboutBlank {
            return live
        }
        if case .browser(let stored) = ws.inspector.browser.kind, stored != .aboutBlank {
            return stored
        }
        return nil
    }

    /// Write a screenshot PNG to `path`, mapping a filesystem error to a concise
    /// message — the raw NSError renders a verbose "Error Domain=NSCocoaErrorDomain…"
    /// string in the JSON error.
    private static func writeScreenshot(_ png: Data, to path: String) throws {
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            throw BrowserOpError(
                message: "cannot write screenshot to '\(path)': \(error.localizedDescription)")
        }
    }

    /// Evaluate `script` in the browser page. Returns the JSON-serialized result.
    func controlBrowserEval(_ script: String, in workspaceID: UUID) async -> Result<String, BrowserOpError> {
        await withBrowserCoordinator(workspaceID) { try await $0.evaluate(script) }
    }

    /// Return the page's HTML (`outerHTML` of `selector`'s first match, or of the
    /// whole document when `selector` is nil).
    func controlBrowserContent(selector: String?, in workspaceID: UUID) async -> Result<String, BrowserOpError> {
        await withBrowserCoordinator(workspaceID) {
            // `evaluate` returns the string JSON-serialized; unwrap it back to the
            // raw HTML so `content` consumers get plain markup, not a quoted string.
            Self.plainString(fromJSON: try await $0.evaluate(BrowserAutomation.content(selector: selector)))
        }
    }

    /// Return the browser page's current URL (`window.location.href`).
    func controlBrowserURL(in workspaceID: UUID) async -> Result<String, BrowserOpError> {
        await withBrowserCoordinator(workspaceID) {
            // `evaluate` returns the string JSON-serialized; unwrap it back to the
            // raw URL so `url` consumers get a plain string, not a quoted one.
            Self.plainString(fromJSON: try await $0.evaluate(BrowserAutomation.currentURL()))
        }
    }

    /// Run an input-driving script for its side effect only. The action verbs
    /// (click, scroll, type, key) carry no payload, so their reply is always the
    /// empty string and the script's own result is discarded.
    private func runAction(_ js: String, in workspaceID: UUID) async -> Result<String, BrowserOpError> {
        await withBrowserCoordinator(workspaceID) {
            _ = try await $0.evaluate(js)
            return ""
        }
    }

    /// Click the first element matching `selector`.
    func controlBrowserClick(selector: String, in workspaceID: UUID) async -> Result<String, BrowserOpError> {
        await runAction(BrowserAutomation.click(selector: selector), in: workspaceID)
    }

    /// Scroll the browser page one viewport down (`down` true) or up.
    func controlBrowserScroll(down: Bool, in workspaceID: UUID) async -> Result<String, BrowserOpError> {
        await runAction(BrowserAutomation.scroll(down: down), in: workspaceID)
    }

    /// Jump the browser page to the very bottom (`bottom` true) or top.
    func controlBrowserScrollToEdge(bottom: Bool, in workspaceID: UUID) async -> Result<String, BrowserOpError> {
        await runAction(BrowserAutomation.scrollToEdge(bottom: bottom), in: workspaceID)
    }

    /// Type `value` into the first element matching `selector`.
    func controlBrowserType(
        selector: String, value: String, in workspaceID: UUID
    ) async -> Result<String, BrowserOpError> {
        await runAction(BrowserAutomation.type(selector: selector, value: value), in: workspaceID)
    }

    /// Dispatch a `keydown`/`keyup` for `key` on `selector`'s match, or on the
    /// focused element when `selector` is nil.
    func controlBrowserKey(
        key: String, selector: String?, in workspaceID: UUID
    ) async -> Result<String, BrowserOpError> {
        await runAction(BrowserAutomation.key(key: key, selector: selector), in: workspaceID)
    }

    /// Return the browser console/error buffer serialized to a JSON array string
    /// (oldest→newest). `level` filters to that severity threshold and above; when
    /// `clear` is set the whole buffer is drained after snapshotting.
    func controlBrowserConsole(
        level: ConsoleLevel?, clear: Bool, in workspaceID: UUID
    ) async -> Result<String, BrowserOpError> {
        await withBrowserCoordinator(workspaceID) { coordinator in
            Self.consoleJSON(coordinator.consoleSnapshot(level: level, clear: clear))
        }
    }

    /// Block until `js` is truthy in the page or the deadline expires. `description`
    /// names what is awaited, for the timeout message.
    func controlBrowserWait(
        js: String, timeoutMs: Int, description: String, in workspaceID: UUID
    ) async -> Result<Void, BrowserOpError> {
        guard let coordinator = inspectorBrowserCoordinator(in: workspaceID) else {
            return .failure(BrowserOpError(message: "workspace not found"))
        }
        if await coordinator.waitFor(js: js, timeoutMs: timeoutMs) {
            return .success(())
        }
        return .failure(BrowserOpError(message: "timed out after \(timeoutMs)ms waiting for \(description)"))
    }

    /// Reload the browser page. When `waitReady`, also block until the document's
    /// `readyState` is `complete` (or the timeout expires).
    func controlBrowserReload(
        waitReady: Bool, timeoutMs: Int, in workspaceID: UUID
    ) async -> Result<Void, BrowserOpError> {
        guard let coordinator = inspectorBrowserCoordinator(in: workspaceID) else {
            return .failure(BrowserOpError(message: "workspace not found"))
        }
        coordinator.reload()
        guard waitReady else { return .success(()) }
        if await coordinator.waitFor(js: BrowserAutomation.readyStateCompleteJS(), timeoutMs: timeoutMs) {
            return .success(())
        }
        return .failure(BrowserOpError(message: "timed out after \(timeoutMs)ms waiting for the page to reload"))
    }

    /// Encoder for the console entry array: sorted keys for deterministic output,
    /// unescaped slashes so embedded URLs stay readable.
    private static let consoleEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// Serialize console entries to a JSON array string, falling back to `[]` on the
    /// (never-expected) encoding failure.
    private static func consoleJSON(_ entries: [ConsoleEntry]) -> String {
        guard let data = try? consoleEncoder.encode(entries),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }

    /// Decode a single JSON string value (as produced by `BrowserCoordinator`'s
    /// `evaluate`) back to its plain contents. Falls back to the input unchanged
    /// when it isn't a JSON string (should not happen for `content`).
    private static func plainString(fromJSON json: String) -> String {
        guard let data = json.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let string = value as? String else {
            return json
        }
        return string
    }
}
