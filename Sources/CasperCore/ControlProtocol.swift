import Foundation

/// A single command sent from the `casper` CLI to the running app over the
/// release control socket. One flat struct (not an enum with associated values)
/// keeps the JSON wire form trivial and stable across the CLI/app boundary —
/// mirroring the DEBUG `DebugCommand` design.
public struct ControlCommand: Codable, Equatable, Sendable {
    public enum Verb: String, Codable, Sendable {
        case statusSet
        case progressSet
        case progressClear
        case notify
        case terminalNew
        case browserOpen
        case diffShow
        case workspaceList
        case workspaceNew
    }

    public var verb: Verb
    public var workspace: String?   // target selector: workspace id or name (nil = app's selected)
    public var state: String?       // statusSet: AgentState raw value
    public var total: Int?          // progressSet
    public var current: Int?        // progressSet
    public var label: String?       // progressSet
    public var message: String?     // notify: optional macOS-notification body
    public var url: String?         // browserOpen
    public var target: String?      // diffShow: reserved diff selector (nil = default)
    public var branch: String?      // workspaceNew
    public var base: String?        // workspaceNew

    public init(
        verb: Verb, workspace: String? = nil, state: String? = nil,
        total: Int? = nil, current: Int? = nil, label: String? = nil,
        message: String? = nil, url: String? = nil, target: String? = nil,
        branch: String? = nil, base: String? = nil
    ) {
        self.verb = verb
        self.workspace = workspace
        self.state = state
        self.total = total
        self.current = current
        self.label = label
        self.message = message
        self.url = url
        self.target = target
        self.branch = branch
        self.base = base
    }
}

/// A workspace summary returned by `workspaceList` / `workspaceNew`.
public struct ControlWorkspaceInfo: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var branch: String

    public init(id: String, name: String, branch: String) {
        self.id = id
        self.name = name
        self.branch = branch
    }
}

/// The reply to a `ControlCommand`. `text` carries a scalar result (e.g. a new
/// workspace id); `workspaces` carries list results; `error` is set when `ok`
/// is false.
public struct ControlResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var text: String?
    /// The resolved target workspace id, so the CLI can echo which workspace an
    /// action actually acted on.
    public var workspace: String?
    public var workspaces: [ControlWorkspaceInfo]?
    public var error: String?

    public init(
        ok: Bool, text: String? = nil, workspace: String? = nil,
        workspaces: [ControlWorkspaceInfo]? = nil, error: String? = nil
    ) {
        self.ok = ok
        self.text = text
        self.workspace = workspace
        self.workspaces = workspaces
        self.error = error
    }

    public static func success(
        text: String? = nil, workspaces: [ControlWorkspaceInfo]? = nil,
        workspace: String? = nil
    ) -> ControlResponse {
        ControlResponse(ok: true, text: text, workspace: workspace, workspaces: workspaces)
    }

    public static func failure(_ message: String) -> ControlResponse {
        ControlResponse(ok: false, error: message)
    }
}
