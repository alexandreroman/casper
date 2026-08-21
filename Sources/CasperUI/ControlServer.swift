import CasperCore
import Foundation

/// Owns the release control socket and dispatches each `ControlCommand` to
/// `AppModel` on the main actor. The CasperUI counterpart of the DEBUG-only
/// `DebugServer` — but shipping in release.
@MainActor
final class ControlServer {
    private let server: ControlSocketServer
    private weak var model: AppModel?

    init(socketPath: String, model: AppModel) {
        self.model = model
        self.server = ControlSocketServer(socketPath: socketPath)
        server.onCommand = { [weak self] command, reply in
            // Hop from the socket's serial queue onto the main actor to touch AppModel.
            Task { @MainActor in
                guard let self else { reply(.failure("server gone")); return }
                self.handle(command, reply: reply)
            }
        }
        server.onFailure = { CasperLog.app.failure("control socket listener failed", $0) }
    }

    func start() throws { try server.start() }
    func stop() { server.stop() }

    /// Dispatches one decoded command to the matching `AppModel.control*` handler.
    /// `internal` (not `private`) so `ControlServerTests` can call it directly
    /// without going through a real socket.
    func handle(_ command: ControlCommand, reply: @escaping @Sendable (ControlResponse) -> Void) {
        guard let model else { reply(.failure("app model unavailable")); return }

        // Commands that do not target a single existing workspace.
        switch command.verb {
        case .workspaceList:
            reply(.success(workspaces: model.controlListWorkspaces())); return
        case .workspaceNew:
            guard let id = model.controlResolveWorkspaceID(selector: command.workspace) else {
                reply(.failure(Self.targetError(command.workspace))); return
            }
            guard let branch = command.branch else { reply(.failure("missing branch")); return }
            switch model.controlCreateWorkspace(
                inSpaceOf: id, branch: branch, base: command.base, command: command.command) {
            case .success(let info): reply(.success(text: info.id, workspaces: [info])); return
            case .failure(let error): reply(.failure(error.message)); return
            }
        default:
            break
        }

        // Workspace-scoped commands.
        guard let id = model.controlResolveWorkspaceID(selector: command.workspace) else {
            reply(.failure(Self.targetError(command.workspace))); return
        }
        switch command.verb {
        case .statusSet:
            guard let raw = command.state, let state = AgentState(rawValue: raw) else {
                reply(.failure("invalid state: \(command.state ?? "nil")")); return
            }
            reply(Self.ack(model.controlSetAgentState(state, for: id), workspace: id)); return
        case .progressSet:
            guard let total = command.total, let current = command.current,
                  let label = command.label else { reply(.failure("missing progress fields")); return }
            reply(Self.ack(
                model.controlSetProgress(total: total, current: current, label: label, for: id),
                workspace: id, failure: "invalid progress \(current)/\(total)")); return
        case .progressClear:
            reply(Self.ack(model.controlClearProgress(for: id), workspace: id)); return
        case .notify:
            reply(Self.ack(model.controlRaiseNotification(message: command.message, for: id),
                           workspace: id)); return
        case .infoSet:
            guard let markdown = command.message,
                  !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                reply(.failure("missing or blank message")); return
            }
            guard markdown.utf8.count <= ControlCommand.infoMessageMaxBytes else {
                reply(.failure(
                    "message too large (\(markdown.utf8.count) bytes, max "
                        + "\(ControlCommand.infoMessageMaxBytes))"))
                return
            }
            reply(Self.ack(model.controlSetInfo(markdown: markdown, for: id), workspace: id)); return
        case .infoClear:
            reply(Self.ack(model.controlClearInfo(for: id), workspace: id)); return
        case .terminalNew:
            guard let info = model.controlOpenTerminal(in: id, command: command.command, cwd: command.cwd) else {
                reply(.failure("cannot open terminal")); return
            }
            reply(.success(workspace: id.casperID, terminals: [info])); return
        case .terminalList:
            reply(.success(workspace: id.casperID, terminals: model.controlListTerminals(in: id))); return
        case .terminalClose:
            reply(Self.ack(model.controlCloseTerminal(in: id, terminalID: command.target), workspace: id,
                           failure: "no terminal '\(command.target ?? "")' in this workspace")); return
        case .browserOpen:
            guard let url = Self.parsedURL(command.url) else {
                reply(.failure("invalid url: \(command.url ?? "nil")")); return
            }
            reply(Self.ack(model.controlOpenBrowser(url: url, in: id), workspace: id,
                           failure: "cannot open browser")); return
        case .browserLoad:
            guard let url = Self.parsedURL(command.url) else {
                reply(.failure("invalid url: \(command.url ?? "nil")")); return
            }
            reply(Self.ack(model.controlLoadBrowser(url: url, in: id), workspace: id,
                           failure: "cannot load browser")); return
        case .browserClose:
            reply(Self.ack(model.controlCloseBrowser(in: id), workspace: id,
                           failure: "cannot close browser")); return
        case .diffOpen:
            switch model.controlOpenDiff(in: id, file: command.target) {
            case .success: reply(.success(workspace: id.casperID)); return
            case .failure(let error): reply(.failure(error.message)); return
            }
        case .diffClose:
            reply(Self.ack(model.controlCloseDiff(in: id), workspace: id,
                           failure: "cannot close diff")); return
        case .workspaceDelete:
            model.controlDeleteWorkspace(id: id) { result in
                switch result {
                case .success: reply(.success(workspace: id.casperID))
                case .failure(let error): reply(.failure(error.message))
                }
            }
            return
        case .run:
            switch model.controlRun(name: command.name, in: id) {
            case .success(let info):
                reply(.success(workspace: id.casperID, terminals: [info])); return
            case .failure(let error):
                reply(.failure(error.message)); return
            }
        // Browser automation is async (WebKit's evaluateJavaScript / takeSnapshot),
        // so — like `workspaceDelete` — these await the AppModel call and reply on
        // completion rather than returning a response synchronously. Each case
        // extracts its arguments from the command, then hands `replyWhenReady` the
        // op to await. `browserWait`/`browserReload` report no payload, so they map
        // their `Void` success to the same empty text the action verbs return.
        case .browserScreenshot:
            let path = command.path ?? ""
            let width = command.width
            let height = command.height
            let url = command.url
            replyWhenReady(workspace: id, reply: reply) {
                await model.browserAutomation.controlBrowserScreenshot(
                    in: id, to: path, width: width, height: height, url: url)
            }
            return
        case .browserEval:
            guard let script = command.script else { reply(.failure("missing script")); return }
            replyWhenReady(workspace: id, reply: reply) {
                await model.browserAutomation.controlBrowserEval(script, in: id)
            }
            return
        case .browserContent:
            let selector = command.selector
            replyWhenReady(workspace: id, reply: reply) {
                await model.browserAutomation.controlBrowserContent(selector: selector, in: id)
            }
            return
        case .browserURL:
            replyWhenReady(workspace: id, reply: reply) {
                await model.browserAutomation.controlBrowserURL(in: id)
            }
            return
        case .browserClick:
            guard let selector = command.selector else { reply(.failure("missing selector")); return }
            replyWhenReady(workspace: id, reply: reply) {
                await model.browserAutomation.controlBrowserClick(selector: selector, in: id)
            }
            return
        case .browserType:
            guard let selector = command.selector else { reply(.failure("missing selector")); return }
            let value = command.value ?? ""
            replyWhenReady(workspace: id, reply: reply) {
                await model.browserAutomation.controlBrowserType(selector: selector, value: value, in: id)
            }
            return
        case .browserKey:
            guard let key = command.key else { reply(.failure("missing key")); return }
            let selector = command.selector
            replyWhenReady(workspace: id, reply: reply) {
                await model.browserAutomation.controlBrowserKey(key: key, selector: selector, in: id)
            }
            return
        case .browserConsole:
            let level = command.level.flatMap { ConsoleLevel(rawValue: $0) }
            let clear = command.clear ?? false
            replyWhenReady(workspace: id, reply: reply) {
                await model.browserAutomation.controlBrowserConsole(level: level, clear: clear, in: id)
            }
            return
        case .browserWait:
            guard let (predicate, description) = Self.waitPredicate(for: command) else {
                reply(.failure("wait needs a <selector> or --js <expr>")); return
            }
            let timeout = command.waitTimeout ?? 5000
            replyWhenReady(workspace: id, reply: reply) {
                await model.browserAutomation.controlBrowserWait(
                    js: predicate, timeoutMs: timeout, description: description, in: id).map { _ in "" }
            }
            return
        case .browserReload:
            let waitReady = command.waitReady ?? false
            let timeout = command.waitTimeout ?? 5000
            replyWhenReady(workspace: id, reply: reply) {
                await model.browserAutomation.controlBrowserReload(
                    waitReady: waitReady, timeoutMs: timeout, in: id).map { _ in "" }
            }
            return
        // The four scroll verbs differ only in which call they make — a step or a
        // jump to the edge — and in the direction.
        case .browserScrollUp, .browserScrollDown, .browserScrollTop, .browserScrollBottom:
            let toEdge = command.verb == .browserScrollTop || command.verb == .browserScrollBottom
            let towardEnd = command.verb == .browserScrollDown || command.verb == .browserScrollBottom
            replyWhenReady(workspace: id, reply: reply) {
                let automation = model.browserAutomation
                return toEdge
                    ? await automation.controlBrowserScrollToEdge(bottom: towardEnd, in: id)
                    : await automation.controlBrowserScroll(down: towardEnd, in: id)
            }
            return
        case .workspaceList, .workspaceNew:
            reply(.failure("unreachable")); return  // handled above
        }
    }

    /// Await one browser-automation op on the main actor and send its outcome as
    /// the command's reply. Kept separate from the dispatch switch so each browser
    /// case is just its argument extraction plus the op to run.
    private func replyWhenReady(
        workspace id: UUID,
        reply: @escaping @Sendable (ControlResponse) -> Void,
        _ op: @escaping @MainActor () async -> Result<String, BrowserOpError>
    ) {
        Task { @MainActor in
            reply(Self.browserReply(await op(), workspace: id))
        }
    }

    /// The `--url` argument, accepted only as an absolute URL: a bare path or any
    /// string without both a scheme and a host is rejected rather than loaded.
    private static func parsedURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), url.scheme != nil, url.host != nil else { return nil }
        return url
    }

    /// The acknowledgement a workspace-scoped command replies with: the workspace id
    /// on success, `failure` otherwise.
    private static func ack(
        _ succeeded: Bool, workspace id: UUID, failure: String = "workspace not found"
    ) -> ControlResponse {
        succeeded ? .success(workspace: id.casperID) : .failure(failure)
    }

    /// Build the wait predicate JS and a human description from a `browserWait`
    /// command. `--js` passes the user expression through unchanged; a selector maps
    /// to presence / visibility / absence via `BrowserAutomation`. Nil when neither
    /// a selector nor a predicate was supplied.
    private static func waitPredicate(for command: ControlCommand) -> (js: String, description: String)? {
        if let predicate = command.predicate {
            return (predicate, "the js predicate")
        }
        guard let selector = command.selector else { return nil }
        if command.gone == true {
            return (BrowserAutomation.goneJS(selector: selector), "'\(selector)' to disappear")
        }
        if command.visible == true {
            return (BrowserAutomation.visibleJS(selector: selector), "'\(selector)' to be visible")
        }
        return (BrowserAutomation.presenceJS(selector: selector), "'\(selector)'")
    }

    /// Map a browser-automation outcome to a control response: success carries the
    /// payload (eval result / HTML / screenshot path, empty for action verbs) in
    /// `text`; failure carries the error message.
    private static func browserReply(
        _ result: Result<String, BrowserOpError>, workspace id: UUID
    ) -> ControlResponse {
        switch result {
        case .success(let text): return .success(text: text, workspace: id.casperID)
        case .failure(let error): return .failure(error.message)
        }
    }

    private static func targetError(_ selector: String?) -> String {
        if let selector { return "no workspace matching '\(selector)'" }
        return "no target workspace (run inside a Casper terminal or pass --workspace)"
    }
}
