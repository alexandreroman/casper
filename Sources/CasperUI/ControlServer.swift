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
            reply(model.controlSetAgentState(state, for: id)
                ? .success(workspace: id.uuidString) : .failure("workspace not found")); return
        case .progressSet:
            guard let total = command.total, let current = command.current,
                  let label = command.label else { reply(.failure("missing progress fields")); return }
            reply(model.controlSetProgress(total: total, current: current, label: label, for: id)
                ? .success(workspace: id.uuidString) : .failure("invalid progress \(current)/\(total)")); return
        case .progressClear:
            reply(model.controlClearProgress(for: id)
                ? .success(workspace: id.uuidString) : .failure("workspace not found")); return
        case .notify:
            reply(model.controlRaiseNotification(message: command.message, for: id)
                ? .success(workspace: id.uuidString) : .failure("workspace not found")); return
        case .terminalNew:
            guard let info = model.controlOpenTerminal(in: id, command: command.command, cwd: command.cwd) else {
                reply(.failure("cannot open terminal")); return
            }
            reply(.success(workspace: id.uuidString, terminals: [info])); return
        case .terminalList:
            reply(.success(workspace: id.uuidString, terminals: model.controlListTerminals(in: id))); return
        case .terminalClose:
            reply(model.controlCloseTerminal(in: id, terminalID: command.target)
                ? .success(workspace: id.uuidString)
                : .failure("no terminal '\(command.target ?? "")' in this workspace")); return
        case .browserOpen:
            guard let raw = command.url, let url = URL(string: raw), url.scheme != nil, url.host != nil else {
                reply(.failure("invalid url: \(command.url ?? "nil")")); return
            }
            reply(model.controlOpenBrowser(url: url, in: id)
                ? .success(workspace: id.uuidString) : .failure("cannot open browser")); return
        case .browserClose:
            reply(model.controlCloseBrowser(in: id)
                ? .success(workspace: id.uuidString) : .failure("cannot close browser")); return
        case .diffOpen:
            switch model.controlOpenDiff(in: id, file: command.target) {
            case .success: reply(.success(workspace: id.uuidString)); return
            case .failure(let error): reply(.failure(error.message)); return
            }
        case .diffClose:
            reply(model.controlCloseDiff(in: id)
                ? .success(workspace: id.uuidString) : .failure("cannot close diff")); return
        case .workspaceDelete:
            model.controlDeleteWorkspace(id: id) { result in
                switch result {
                case .success: reply(.success(workspace: id.uuidString))
                case .failure(let error): reply(.failure(error.message))
                }
            }
            return
        case .run:
            switch model.controlRun(name: command.name, in: id) {
            case .success(let info):
                reply(.success(workspace: id.uuidString, terminals: [info])); return
            case .failure(let error):
                reply(.failure(error.message)); return
            }
        // Browser automation is async (WebKit's evaluateJavaScript / takeSnapshot),
        // so — like `workspaceDelete` — these await the AppModel call and reply on
        // completion rather than returning a response synchronously.
        case .browserScreenshot:
            let path = command.path ?? ""
            Task { @MainActor in
                reply(Self.browserReply(await model.controlBrowserScreenshot(in: id, to: path), workspace: id))
            }
            return
        case .browserEval:
            guard let script = command.script else { reply(.failure("missing script")); return }
            Task { @MainActor in
                reply(Self.browserReply(await model.controlBrowserEval(script, in: id), workspace: id))
            }
            return
        case .browserContent:
            let selector = command.selector
            Task { @MainActor in
                reply(Self.browserReply(
                    await model.controlBrowserContent(selector: selector, in: id), workspace: id))
            }
            return
        case .browserClick:
            guard let selector = command.selector else { reply(.failure("missing selector")); return }
            Task { @MainActor in
                reply(Self.browserReply(await model.controlBrowserClick(selector: selector, in: id), workspace: id))
            }
            return
        case .browserType:
            guard let selector = command.selector else { reply(.failure("missing selector")); return }
            let value = command.value ?? ""
            Task { @MainActor in
                reply(Self.browserReply(
                    await model.controlBrowserType(selector: selector, value: value, in: id), workspace: id))
            }
            return
        case .browserKey:
            guard let key = command.key else { reply(.failure("missing key")); return }
            let selector = command.selector
            Task { @MainActor in
                reply(Self.browserReply(
                    await model.controlBrowserKey(key: key, selector: selector, in: id), workspace: id))
            }
            return
        case .workspaceList, .workspaceNew:
            reply(.failure("unreachable")); return  // handled above
        }
    }

    /// Map a browser-automation outcome to a control response: success carries the
    /// payload (eval result / HTML / screenshot path, empty for action verbs) in
    /// `text`; failure carries the error message.
    private static func browserReply(
        _ result: Result<String, AppModel.BrowserOpError>, workspace id: UUID
    ) -> ControlResponse {
        switch result {
        case .success(let text): return .success(text: text, workspace: id.uuidString)
        case .failure(let error): return .failure(error.message)
        }
    }

    private static func targetError(_ selector: String?) -> String {
        if let selector { return "no workspace matching '\(selector)'" }
        return "no target workspace (run inside a Casper terminal or pass --workspace)"
    }
}
