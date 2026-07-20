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
        case terminalList
        case terminalClose
        case browserOpen
        case browserLoad
        case browserClose
        case diffOpen
        case diffClose
        case workspaceList
        case workspaceNew
        case workspaceDelete
        case run
        case browserScreenshot
        case browserEval
        case browserContent
        case browserURL
        case browserClick
        case browserType
        case browserKey
        case browserConsole
        case browserWait
        case browserReload
        case browserScrollUp
        case browserScrollDown
        case browserScrollTop
        case browserScrollBottom
    }

    public var verb: Verb
    public var workspace: String?   // target selector: workspace id or name (nil = app's selected)
    public var state: String?       // statusSet: AgentState raw value
    public var total: Int?          // progressSet
    public var current: Int?        // progressSet
    public var label: String?       // progressSet
    public var message: String?     // notify: optional macOS-notification body
    public var url: String?         // browserOpen
    public var target: String?      // diffOpen: file path to scroll to; terminalClose: terminal id
    public var branch: String?      // workspaceNew
    public var base: String?        // workspaceNew
    public var command: String?     // terminalNew / workspaceNew: optional command to run
    public var cwd: String?         // terminalNew: optional working directory
    public var name: String?        // run: named command from .casper.json
    public var script: String?      // browserEval: JavaScript source to evaluate
    public var selector: String?    // browserClick/Type/Key/Content: CSS selector target
    public var value: String?       // browserType: text to type into the element
    public var key: String?         // browserKey: key name (e.g. Enter, Escape)
    public var path: String?        // browserScreenshot: output PNG path
    public var level: String?       // browserConsole: severity threshold (ConsoleLevel raw value)
    public var predicate: String?   // browserWait: JavaScript predicate (--js form)
    public var waitTimeout: Int?    // browserWait/browserReload: deadline in milliseconds
    public var clear: Bool?         // browserConsole: drain the buffer after reading
    public var visible: Bool?       // browserWait: require the selector to be visible
    public var gone: Bool?          // browserWait: require the selector to be absent
    public var waitReady: Bool?     // browserReload: also wait for readyState === "complete"
    public var width: Int?          // browserScreenshot: off-screen render viewport width
    public var height: Int?         // browserScreenshot: off-screen render viewport height

    public init(
        verb: Verb, workspace: String? = nil, state: String? = nil,
        total: Int? = nil, current: Int? = nil, label: String? = nil,
        message: String? = nil, url: String? = nil, target: String? = nil,
        branch: String? = nil, base: String? = nil,
        command: String? = nil, cwd: String? = nil, name: String? = nil,
        script: String? = nil, selector: String? = nil, value: String? = nil,
        key: String? = nil, path: String? = nil,
        level: String? = nil, predicate: String? = nil, waitTimeout: Int? = nil,
        clear: Bool? = nil, visible: Bool? = nil, gone: Bool? = nil, waitReady: Bool? = nil,
        width: Int? = nil, height: Int? = nil
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
        self.command = command
        self.cwd = cwd
        self.name = name
        self.script = script
        self.selector = selector
        self.value = value
        self.key = key
        self.path = path
        self.level = level
        self.predicate = predicate
        self.waitTimeout = waitTimeout
        self.clear = clear
        self.visible = visible
        self.gone = gone
        self.waitReady = waitReady
        self.width = width
        self.height = height
    }
}

/// A severity level for a captured `console.*` call, ordered `debug < log < info
/// < warn < error`. `browser console --level` uses this ordering as a threshold:
/// `--level warn` returns `warn` and `error` entries only. `Comparable` is
/// derived from the fixed `severity` rank so callers can filter with `>=`.
public enum ConsoleLevel: String, Codable, Sendable, CaseIterable, Comparable {
    case debug
    case log
    case info
    case warn
    case error

    /// Fixed severity rank (`debug` lowest, `error` highest) backing `Comparable`.
    private var severity: Int {
        switch self {
        case .debug: return 0
        case .log: return 1
        case .info: return 2
        case .warn: return 3
        case .error: return 4
        }
    }

    public static func < (lhs: ConsoleLevel, rhs: ConsoleLevel) -> Bool {
        lhs.severity < rhs.severity
    }
}

/// A single captured console message or uncaught error/rejection from a browser
/// page. Serialized to a JSON array in `ControlResponse.text` for `browser
/// console`; each optional key is emitted only when known. `timestamp` is epoch
/// milliseconds (`Date.now()`), matching the JS-side capture.
public struct ConsoleEntry: Codable, Equatable, Sendable {
    public var level: String
    public var message: String
    public var timestamp: Double
    public var source: String?
    public var line: Int?
    public var column: Int?
    public var stack: String?

    public init(
        level: String, message: String, timestamp: Double,
        source: String? = nil, line: Int? = nil, column: Int? = nil, stack: String? = nil
    ) {
        self.level = level
        self.message = message
        self.timestamp = timestamp
        self.source = source
        self.line = line
        self.column = column
        self.stack = stack
    }
}

/// A workspace summary returned by `workspaceList` / `workspaceNew`.
public struct ControlWorkspaceInfo: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var branch: String
    public var path: String

    public init(id: String, name: String, branch: String, path: String) {
        self.id = id
        self.name = name
        self.branch = branch
        self.path = path
    }
}

/// A terminal surface summary returned by `terminalNew`/`terminalList`.
public struct ControlTerminalInfo: Codable, Equatable, Sendable {
    public var id: String
    public var cwd: String

    public init(id: String, cwd: String) {
        self.id = id
        self.cwd = cwd
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
    public var terminals: [ControlTerminalInfo]?
    public var error: String?

    public init(
        ok: Bool, text: String? = nil, workspace: String? = nil,
        workspaces: [ControlWorkspaceInfo]? = nil, terminals: [ControlTerminalInfo]? = nil,
        error: String? = nil
    ) {
        self.ok = ok
        self.text = text
        self.workspace = workspace
        self.workspaces = workspaces
        self.terminals = terminals
        self.error = error
    }

    public static func success(
        text: String? = nil, workspace: String? = nil,
        workspaces: [ControlWorkspaceInfo]? = nil, terminals: [ControlTerminalInfo]? = nil
    ) -> ControlResponse {
        ControlResponse(
            ok: true, text: text, workspace: workspace, workspaces: workspaces,
            terminals: terminals)
    }

    public static func failure(_ message: String) -> ControlResponse {
        ControlResponse(ok: false, error: message)
    }
}
