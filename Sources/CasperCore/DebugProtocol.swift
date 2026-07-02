#if DEBUG
import Foundation

/// A single debug command sent from `casper debug` to the running GUI.
/// One flat struct (rather than an enum with associated values) keeps the JSON
/// wire form trivial and stable across the CLI/app boundary.
public struct DebugCommand: Codable, Equatable, Sendable {
    public enum Verb: String, Codable, Sendable {
        case dumpState
        case readText
        case sendText
        case screenshot
        case focus
    }

    public var verb: Verb
    public var text: String?        // sendText payload
    public var enter: Bool?         // sendText: append a trailing newline
    public var scrollback: Bool?    // readText: full screen vs. viewport
    public var path: String?        // screenshot: output file path
    public var target: String?      // surface id to address (nil = focused/first)

    public init(
        verb: Verb, text: String? = nil, enter: Bool? = nil,
        scrollback: Bool? = nil, path: String? = nil, target: String? = nil
    ) {
        self.verb = verb
        self.text = text
        self.enter = enter
        self.scrollback = scrollback
        self.path = path
        self.target = target
    }
}

/// Snapshot of the app's observable UI state, returned by `dumpState`.
public struct DebugState: Codable, Equatable, Sendable {
    public struct Surface: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var workingDirectory: String?
        public var columns: Int
        public var rows: Int
        public var focused: Bool

        public init(
            id: String, title: String, workingDirectory: String?,
            columns: Int, rows: Int, focused: Bool
        ) {
            self.id = id
            self.title = title
            self.workingDirectory = workingDirectory
            self.columns = columns
            self.rows = rows
            self.focused = focused
        }
    }

    public var surfaces: [Surface]

    public init(surfaces: [Surface]) { self.surfaces = surfaces }
}

/// The reply to a `DebugCommand`. `text` carries read-text output or a
/// screenshot path; `state` carries a `dumpState` snapshot; `error` is set when
/// `ok` is false.
public struct DebugResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var text: String?
    public var state: DebugState?
    public var error: String?

    public init(ok: Bool, text: String? = nil, state: DebugState? = nil, error: String? = nil) {
        self.ok = ok
        self.text = text
        self.state = state
        self.error = error
    }

    public static func success(text: String? = nil, state: DebugState? = nil) -> DebugResponse {
        DebugResponse(ok: true, text: text, state: state)
    }

    public static func failure(_ message: String) -> DebugResponse {
        DebugResponse(ok: false, error: message)
    }
}
#endif
