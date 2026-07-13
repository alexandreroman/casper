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

    func testDiffCloseDispatch() throws {
        let (server, id) = try seededServer()
        let response = handleSync(server, ControlCommand(verb: .diffClose, workspace: id.uuidString))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.workspace, id.uuidString)
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
