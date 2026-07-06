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
            Task { @MainActor in reply(self?.handle(command) ?? .failure("server gone")) }
        }
    }

    func start() throws { try server.start() }
    func stop() { server.stop() }

    /// Dispatches one decoded command to the matching `AppModel.control*` handler.
    /// `internal` (not `private`) so `ControlServerTests` can call it directly
    /// without going through a real socket.
    func handle(_ command: ControlCommand) -> ControlResponse {
        guard let model else { return .failure("app model unavailable") }

        // Commands that do not target a single existing workspace.
        switch command.verb {
        case .workspaceList:
            return .success(workspaces: model.controlListWorkspaces())
        case .workspaceNew:
            guard let id = model.controlResolveWorkspaceID(selector: command.workspace) else {
                return .failure(Self.targetError(command.workspace))
            }
            guard let branch = command.branch else { return .failure("missing branch") }
            switch model.controlCreateWorkspace(inSpaceOf: id, branch: branch, base: command.base) {
            case .success(let info): return .success(text: info.id, workspaces: [info])
            case .failure(let error): return .failure(error.message)
            }
        default:
            break
        }

        // Workspace-scoped commands.
        guard let id = model.controlResolveWorkspaceID(selector: command.workspace) else {
            return .failure(Self.targetError(command.workspace))
        }
        switch command.verb {
        case .statusSet:
            guard let raw = command.state, let state = AgentState(rawValue: raw), state != .unknown else {
                return .failure("invalid state: \(command.state ?? "nil")")
            }
            return model.controlSetAgentState(state, for: id)
                ? .success() : .failure("workspace not found")
        case .progressSet:
            guard let total = command.total, let current = command.current,
                  let label = command.label else { return .failure("missing progress fields") }
            return model.controlSetProgress(total: total, current: current, label: label, for: id)
                ? .success() : .failure("invalid progress \(current)/\(total)")
        case .progressClear:
            return model.controlClearProgress(for: id) ? .success() : .failure("workspace not found")
        case .notify:
            return model.controlRaiseNotification(message: command.message, for: id)
                ? .success() : .failure("workspace not found")
        case .terminalNew:
            return model.controlOpenTerminal(in: id) ? .success() : .failure("cannot open terminal")
        case .browserOpen:
            guard let raw = command.url, let url = URL(string: raw) else {
                return .failure("invalid url: \(command.url ?? "nil")")
            }
            return model.controlOpenBrowser(url: url, in: id) ? .success() : .failure("cannot open browser")
        case .diffShow:
            return model.controlShowDiff(in: id) ? .success() : .failure("workspace not found")
        case .workspaceList, .workspaceNew:
            return .failure("unreachable")  // handled above
        }
    }

    private static func targetError(_ selector: String?) -> String {
        if let selector { return "no workspace matching '\(selector)'" }
        return "no target workspace (run inside a Casper terminal or pass --workspace)"
    }
}
