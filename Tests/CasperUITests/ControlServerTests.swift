import XCTest
import CasperCore
@testable import CasperUI

/// `handle(_:)` dispatch coverage only — no real socket. `ControlSocketServer`'s
/// own transport is exercised in `CasperCoreTests`; this suite checks that
/// `ControlServer` routes each verb to the right `AppModel.control*` handler.
@MainActor
final class ControlServerTests: XCTestCase {
    /// `ControlServer` only weak-refs its model (matching `DebugServer`'s weak
    /// `provider`, safe in production because `AppDelegate` keeps `AppModel.shared`
    /// retained for the app's lifetime). A test's `AppModel` has no such owner, so
    /// this test case holds the only strong reference — stored here, not in a
    /// local returned from `seededServer()`, so it stays alive for the whole test
    /// method instead of being released as soon as its last local use passes.
    private var model: AppModel?

    /// A model seeded with one Git-less space + workspace, mirroring
    /// `ControlHandlerTests.seededModel()`: `AppModel(sessionStore:)` alone starts
    /// empty (it defaults to `Session()`, not a load from disk), so the seeded
    /// `Session` is passed directly to the initializer.
    private func seededServer(browserURL: URL? = nil) throws -> (ControlServer, UUID) {
        // A caller can seed the inspector's browser surface with a real page URL so
        // the get-or-create coordinator loads it; otherwise the default blank one.
        let inspector = browserURL.map { InspectorState(browser: Surface(kind: .browser(url: $0))) }
            ?? InspectorState()
        let ws = Workspace(
            name: "main", worktreePath: "/wt", branch: "main",
            portBase: 40000, layout: .leaf(Surface(kind: .terminal(cwd: "/wt"))),
            inspector: inspector)
        let space = Space(name: "main", folderPath: "/wt", isGitRepo: false, workspaces: [ws])
        let url = URL(fileURLWithPath:
            (NSTemporaryDirectory() as NSString).appendingPathComponent("s-\(UUID().uuidString).json"))
        let store = SessionStore(fileURL: url)
        let session = Session(spaces: [space], selectedWorkspaceID: ws.id)
        let model = AppModel(sessionStore: store, session: session)
        self.model = model
        return (ControlServer(socketPath: "/unused-in-dispatch-test.sock", model: model), ws.id)
    }

    /// `ControlServer.handle` delivers its response through an `@Sendable` reply
    /// closure. Every verb these tests exercise replies synchronously on the main
    /// actor, so this helper captures that single response and returns it. The box
    /// is `@unchecked Sendable` only to satisfy the `@Sendable` reply signature —
    /// the write always happens synchronously on this actor.
    private func handleSync(_ server: ControlServer, _ command: ControlCommand) -> ControlResponse {
        final class Box: @unchecked Sendable { var response: ControlResponse? }
        let box = Box()
        server.handle(command) { box.response = $0 }
        return box.response!
    }

    func testStatusSetDispatch() throws {
        let (server, id) = try seededServer()
        let response = handleSync(
            server, ControlCommand(verb: .statusSet, workspace: id.uuidString, state: "blocked"))
        XCTAssertTrue(response.ok)
    }

    func testStatusSetRejectsUnknownState() throws {
        let (server, id) = try seededServer()
        let response = handleSync(
            server, ControlCommand(verb: .statusSet, workspace: id.uuidString, state: "bogus"))
        XCTAssertFalse(response.ok)
    }

    func testUnresolvableTargetFails() throws {
        let (server, _) = try seededServer()
        let response = handleSync(server, ControlCommand(verb: .diffOpen, workspace: "ghost"))
        XCTAssertFalse(response.ok)
        XCTAssertNotNil(response.error)
    }

    func testWorkspaceListDispatch() throws {
        let (server, _) = try seededServer()
        let response = handleSync(server, ControlCommand(verb: .workspaceList))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.workspaces?.count, 1)
    }

    func testBrowserCloseDispatch() throws {
        let (server, id) = try seededServer()
        let response = handleSync(server, ControlCommand(verb: .browserClose, workspace: id.uuidString))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.workspace, id.uuidString)
    }

    func testBrowserLoadDispatch() throws {
        let (server, id) = try seededServer()
        let response = handleSync(
            server, ControlCommand(verb: .browserLoad, workspace: id.uuidString, url: "https://example.com"))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.workspace, id.uuidString)
    }

    func testBrowserLoadRejectsInvalidURL() throws {
        let (server, id) = try seededServer()
        let response = handleSync(
            server, ControlCommand(verb: .browserLoad, workspace: id.uuidString, url: "not-a-url"))
        XCTAssertFalse(response.ok)
        XCTAssertNotNil(response.error)
    }

    /// `browser load` differs from `browser open` in exactly one way: it must NOT
    /// touch the inspector (no tab switch, no expand). Seeded from the defaults
    /// (collapsed, diff tab), a load leaves both untouched, whereas an open selects
    /// the browser tab and expands the panel.
    func testBrowserLoadLeavesInspectorUntouchedWhileOpenChangesIt() throws {
        let (server, id) = try seededServer()
        let model = try XCTUnwrap(self.model)

        // Sanity-check the seeded defaults the behaviour is contrasted against.
        XCTAssertEqual(model.workspace(id: id)?.inspector.tab, .diff)
        XCTAssertEqual(model.workspace(id: id)?.inspector.collapsed, true)

        let load = handleSync(
            server, ControlCommand(verb: .browserLoad, workspace: id.uuidString, url: "https://example.com"))
        XCTAssertTrue(load.ok)
        XCTAssertEqual(model.workspace(id: id)?.inspector.tab, .diff, "load must not switch the tab")
        XCTAssertEqual(model.workspace(id: id)?.inspector.collapsed, true, "load must not expand the panel")

        let open = handleSync(
            server, ControlCommand(verb: .browserOpen, workspace: id.uuidString, url: "https://example.com"))
        XCTAssertTrue(open.ok)
        XCTAssertEqual(model.workspace(id: id)?.inspector.tab, .browser, "open selects the browser tab")
        XCTAssertEqual(model.workspace(id: id)?.inspector.collapsed, false, "open expands the panel")
    }

    func testDiffCloseDispatch() throws {
        let (server, id) = try seededServer()
        let response = handleSync(server, ControlCommand(verb: .diffClose, workspace: id.uuidString))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.workspace, id.uuidString)
    }

    func testInfoSetRoutesToTheModel() throws {
        let (server, id) = try seededServer()
        let model = try XCTUnwrap(self.model)
        let response = handleSync(
            server, ControlCommand(verb: .infoSet, workspace: id.uuidString, message: "## Ready"))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(model.workspace(id: id)?.infoMarkdown, "## Ready")
    }

    func testInfoSetWithoutMessageFails() throws {
        let (server, id) = try seededServer()
        let response = handleSync(server, ControlCommand(verb: .infoSet, workspace: id.uuidString))
        XCTAssertFalse(response.ok)
    }

    /// The server's own guard trims before checking emptiness — dropping just
    /// that trim would let a whitespace-only message (never rejected by the nil
    /// check above) through to `controlSetInfo`, showing an effectively blank
    /// panel.
    func testInfoSetWithWhitespaceOnlyMessageFails() throws {
        let (server, id) = try seededServer()
        let response = handleSync(
            server, ControlCommand(verb: .infoSet, workspace: id.uuidString, message: "   \n\t "))
        XCTAssertFalse(response.ok)
    }

    /// `InfoCommand.Set` enforces `infoMessageMaxBytes` client-side, but the server
    /// must not trust that: mirror the bound here so an oversized payload sent by
    /// any other caller is rejected too, not stored and rendered by the panel.
    func testInfoSetRejectsAnOversizedMessage() throws {
        let (server, id) = try seededServer()
        let model = try XCTUnwrap(self.model)
        let oversized = String(repeating: "a", count: ControlCommand.infoMessageMaxBytes + 1)

        let response = handleSync(
            server, ControlCommand(verb: .infoSet, workspace: id.uuidString, message: oversized))

        XCTAssertFalse(response.ok)
        XCTAssertNil(model.workspace(id: id)?.infoMarkdown)
    }

    func testInfoClearRoutesToTheModel() throws {
        let (server, id) = try seededServer()
        let model = try XCTUnwrap(self.model)
        model.controlSetInfo(markdown: "## Ready", for: id)

        _ = handleSync(server, ControlCommand(verb: .infoClear, workspace: id.uuidString))

        XCTAssertNil(model.workspace(id: id)?.infoMarkdown)
    }

    // MARK: - Browser automation (async dispatch)

    /// The browser verbs reply asynchronously (WebKit's `evaluateJavaScript` /
    /// `takeSnapshot`), so this awaits the reply the `Task { @MainActor … }`
    /// eventually delivers rather than using the synchronous `handleSync`.
    private func handleAsync(_ server: ControlServer, _ command: ControlCommand) async -> ControlResponse {
        await withCheckedContinuation { continuation in
            server.handle(command) { continuation.resume(returning: $0) }
        }
    }

    func testBrowserEvalRoutesAndReturnsResult() async throws {
        let (server, id) = try seededServer()
        let response = await handleAsync(
            server, ControlCommand(verb: .browserEval, workspace: id.uuidString, script: "1 + 1"))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.text, "2")
        XCTAssertEqual(response.workspace, id.uuidString)
    }

    func testBrowserEvalWithoutScriptFails() async throws {
        let (server, id) = try seededServer()
        let response = await handleAsync(server, ControlCommand(verb: .browserEval, workspace: id.uuidString))
        XCTAssertFalse(response.ok)
    }

    func testBrowserContentReturnsDocumentHTML() async throws {
        let (server, id) = try seededServer()
        let response = await handleAsync(server, ControlCommand(verb: .browserContent, workspace: id.uuidString))
        XCTAssertTrue(response.ok)
        XCTAssertTrue((response.text ?? "").lowercased().contains("<html"))
    }

    func testBrowserURLReturnsCurrentHref() async throws {
        // Seed a data: URL so the page's href is a known, meaningful value. The page
        // loads asynchronously, so poll for readiness (like the DOM-mutation test)
        // before reading the URL back.
        let html = "<html><body><h1>hi</h1></body></html>"
        let encoded = html.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? html
        let (server, id) = try seededServer(browserURL: URL(string: "data:text/html," + encoded)!)

        try await waitForElement(server, id, script: "document.querySelector('h1') !== null")

        let response = await handleAsync(server, ControlCommand(verb: .browserURL, workspace: id.uuidString))
        XCTAssertTrue(response.ok)
        XCTAssertTrue((response.text ?? "").hasPrefix("data:text/html"))
    }

    func testBrowserClickMissingElementFails() async throws {
        let (server, id) = try seededServer()
        let response = await handleAsync(
            server, ControlCommand(verb: .browserClick, workspace: id.uuidString, selector: "#nope"))
        XCTAssertFalse(response.ok)
        XCTAssertTrue((response.error ?? "").contains("no element matches"))
    }

    func testBrowserClickWithoutSelectorFails() async throws {
        let (server, id) = try seededServer()
        let response = await handleAsync(server, ControlCommand(verb: .browserClick, workspace: id.uuidString))
        XCTAssertFalse(response.ok)
    }

    func testBrowserTypeMissingElementFails() async throws {
        let (server, id) = try seededServer()
        let response = await handleAsync(
            server,
            ControlCommand(verb: .browserType, workspace: id.uuidString, selector: "#nope", value: "hi"))
        XCTAssertFalse(response.ok)
        XCTAssertTrue((response.error ?? "").contains("no element matches"))
    }

    func testBrowserKeyOnFocusedElementSucceeds() async throws {
        let (server, id) = try seededServer()
        let response = await handleAsync(
            server, ControlCommand(verb: .browserKey, workspace: id.uuidString, key: "Enter"))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.workspace, id.uuidString)
    }

    func testBrowserScreenshotWritesPNG() async throws {
        // No width/height/url overrides: the live-panel capture path, even for a
        // browser that never navigated (about:blank).
        let (server, id) = try seededServer()
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("shot-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let response = await handleAsync(
            server, ControlCommand(verb: .browserScreenshot, workspace: id.uuidString, path: path))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.text, path)
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size ?? 0, 0)
    }

    func testBrowserScreenshotWithURLUsesOffScreenCapture() async throws {
        // A --url override (plus dimensions) routes to the dedicated off-screen
        // capturer, which loads the URL headlessly — no prior navigation required.
        let html = "<html><body><h1>capture me</h1></body></html>"
        let encoded = html.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? html
        let (server, id) = try seededServer()
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("shot-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let response = await handleAsync(server, ControlCommand(
            verb: .browserScreenshot, workspace: id.uuidString, url: "data:text/html," + encoded,
            path: path, width: 375, height: 800))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.text, path)
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size ?? 0, 0)
    }

    func testBrowserScreenshotSizedWithoutResolvableURLFails() async throws {
        // Sized capture, but the browser never navigated (about:blank) and no --url:
        // nothing resolves to capture, so it fails with a clear message.
        let (server, id) = try seededServer()
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("shot-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let response = await handleAsync(server, ControlCommand(
            verb: .browserScreenshot, workspace: id.uuidString, path: path, width: 375, height: 800))
        XCTAssertFalse(response.ok)
        XCTAssertTrue((response.error ?? "").contains("no page to capture"))
    }

    func testBrowserUnresolvableTargetFails() async throws {
        let (server, _) = try seededServer()
        let response = await handleAsync(server, ControlCommand(verb: .browserEval, workspace: "ghost", script: "1"))
        XCTAssertFalse(response.ok)
        XCTAssertNotNil(response.error)
    }

    /// Positive DOM-mutation path against a real `WKWebView`: click and type on a
    /// loaded `data:` page and observe the effects. Polls for the target element
    /// before acting so the assertions don't race the asynchronous page load.
    func testBrowserClickAndTypeMutateDOM() async throws {
        let html = "<button id='btn' onclick=\"this.textContent='clicked'\">go</button><input id='inp'>"
        let encoded = html.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? html
        let (server, id) = try seededServer(browserURL: URL(string: "data:text/html," + encoded)!)

        try await waitForElement(server, id, script: "document.querySelector('#btn') !== null")

        let click = await handleAsync(
            server, ControlCommand(verb: .browserClick, workspace: id.uuidString, selector: "#btn"))
        XCTAssertTrue(click.ok)
        let afterClick = await handleAsync(
            server,
            ControlCommand(verb: .browserEval, workspace: id.uuidString, script: "document.querySelector('#btn').textContent"))
        XCTAssertEqual(afterClick.text, "\"clicked\"")

        let type = await handleAsync(
            server,
            ControlCommand(verb: .browserType, workspace: id.uuidString, selector: "#inp", value: "hello"))
        XCTAssertTrue(type.ok)
        let afterType = await handleAsync(
            server,
            ControlCommand(verb: .browserEval, workspace: id.uuidString, script: "document.querySelector('#inp').value"))
        XCTAssertEqual(afterType.text, "\"hello\"")
    }

    // MARK: - Console / wait / reload

    func testBrowserConsoleRoutesEmptyBuffer() async throws {
        let (server, id) = try seededServer()
        let response = await handleAsync(server, ControlCommand(verb: .browserConsole, workspace: id.uuidString))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.text, "[]")
        XCTAssertEqual(response.workspace, id.uuidString)
    }

    func testBrowserWaitImmediateTrueSucceeds() async throws {
        let (server, id) = try seededServer()
        let response = await handleAsync(
            server,
            ControlCommand(verb: .browserWait, workspace: id.uuidString, predicate: "true", waitTimeout: 2000))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.workspace, id.uuidString)
    }

    func testBrowserWaitNeverTrueTimesOut() async throws {
        let (server, id) = try seededServer()
        let response = await handleAsync(
            server,
            ControlCommand(verb: .browserWait, workspace: id.uuidString, predicate: "false", waitTimeout: 300))
        XCTAssertFalse(response.ok)
        XCTAssertTrue((response.error ?? "").contains("timed out"))
    }

    func testBrowserWaitWithoutSelectorOrPredicateFails() async throws {
        let (server, id) = try seededServer()
        let response = await handleAsync(server, ControlCommand(verb: .browserWait, workspace: id.uuidString))
        XCTAssertFalse(response.ok)
    }

    func testBrowserWaitUnresolvableTargetFails() async throws {
        let (server, _) = try seededServer()
        let response = await handleAsync(
            server, ControlCommand(verb: .browserWait, workspace: "ghost", predicate: "true"))
        XCTAssertFalse(response.ok)
        XCTAssertNotNil(response.error)
    }

    func testBrowserReloadReturns() async throws {
        let (server, id) = try seededServer()
        let response = await handleAsync(server, ControlCommand(verb: .browserReload, workspace: id.uuidString))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.workspace, id.uuidString)
    }

    func testBrowserScrollUpReturns() async throws {
        let (server, id) = try seededServer()
        let response = await handleAsync(server, ControlCommand(verb: .browserScrollUp, workspace: id.uuidString))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.workspace, id.uuidString)
    }

    func testBrowserScrollDownReturns() async throws {
        let (server, id) = try seededServer()
        let response = await handleAsync(server, ControlCommand(verb: .browserScrollDown, workspace: id.uuidString))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.workspace, id.uuidString)
    }

    func testBrowserScrollTopReturns() async throws {
        let (server, id) = try seededServer()
        let response = await handleAsync(server, ControlCommand(verb: .browserScrollTop, workspace: id.uuidString))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.workspace, id.uuidString)
    }

    func testBrowserScrollBottomReturns() async throws {
        let (server, id) = try seededServer()
        let response = await handleAsync(server, ControlCommand(verb: .browserScrollBottom, workspace: id.uuidString))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.workspace, id.uuidString)
    }

    /// End-to-end against a real `WKWebView`: a `data:` page logs to the console and
    /// throws on load; assert both are captured; wait for an element a `setTimeout`
    /// inserts; and confirm `reload --wait` returns.
    func testBrowserConsoleWaitReloadEndToEnd() async throws {
        let html = """
        <script>
          console.log('hello from page');
          setTimeout(function () {
            var d = document.createElement('div');
            d.id = 'late';
            document.body.appendChild(d);
          }, 100);
          throw new Error('boom on load');
        </script>
        """
        let encoded = html.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? html
        let (server, id) = try seededServer(browserURL: URL(string: "data:text/html," + encoded)!)

        // Poll the console until it has captured both the log and the uncaught error.
        var messages: [String] = []
        for _ in 0..<100 {
            let response = await handleAsync(server, ControlCommand(verb: .browserConsole, workspace: id.uuidString))
            if let text = response.text, let data = text.data(using: .utf8),
               let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
                messages = array.compactMap { $0["message"] as? String }
                if messages.contains(where: { $0.contains("hello from page") })
                    && messages.contains(where: { $0.contains("boom on load") }) { break }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(messages.contains { $0.contains("hello from page") }, "missing console.log; got \(messages)")
        XCTAssertTrue(messages.contains { $0.contains("boom on load") }, "missing uncaught error; got \(messages)")

        // Wait for the element the page's setTimeout inserts.
        let wait = await handleAsync(
            server,
            ControlCommand(verb: .browserWait, workspace: id.uuidString, selector: "#late", waitTimeout: 5000))
        XCTAssertTrue(wait.ok, "wait failed: \(wait.error ?? "")")

        // reload --wait returns once the page finishes reloading.
        let reload = await handleAsync(
            server,
            ControlCommand(verb: .browserReload, workspace: id.uuidString, waitTimeout: 5000, waitReady: true))
        XCTAssertTrue(reload.ok, "reload failed: \(reload.error ?? "")")
    }

    /// Poll `script` (a boolean-returning JS readiness check) until it returns
    /// `true`, so a test acts only after the page has loaded. Fails after ~5 s.
    private func waitForElement(_ server: ControlServer, _ id: UUID, script: String) async throws {
        for _ in 0..<100 {
            let response = await handleAsync(
                server, ControlCommand(verb: .browserEval, workspace: id.uuidString, script: script))
            if response.ok, response.text == "true" { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("page never became ready: \(script)")
    }
}
