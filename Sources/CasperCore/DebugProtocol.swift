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
        case sendKeys
        case sendKey
        case sendAction
        case screenshot
        case focus
    }

    public var verb: Verb
    public var text: String?        // sendText / sendKeys / sendKey / sendAction payload
    public var enter: Bool?         // sendText: submit the line via a Return key event
    public var mods: [String]?      // sendKey: modifier names
    public var scrollback: Bool?    // readText: full screen vs. viewport
    public var path: String?        // screenshot: output file path
    public var target: String?      // surface id to address (nil = focused/first)

    public init(
        verb: Verb, text: String? = nil, enter: Bool? = nil, mods: [String]? = nil,
        scrollback: Bool? = nil, path: String? = nil, target: String? = nil
    ) {
        self.verb = verb
        self.text = text
        self.enter = enter
        self.mods = mods
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
        // Raw geometry, for diagnosing content-scale double-counting.
        // libghostty's `ghostty_surface_size` readback (pixels):
        public var widthPixels: Int
        public var heightPixels: Int
        public var cellWidthPixels: Int
        public var cellHeightPixels: Int
        // The hosting AppKit view's own metrics:
        public var boundsWidth: Double        // view bounds, in points
        public var boundsHeight: Double
        public var backingWidth: Double       // view bounds, in backing pixels
        public var backingHeight: Double
        public var contentScaleX: Double      // points→pixels scale vector
        public var contentScaleY: Double
        public var backingScaleFactor: Double // window.backingScaleFactor

        public init(
            id: String, title: String, workingDirectory: String?,
            columns: Int, rows: Int, focused: Bool,
            widthPixels: Int, heightPixels: Int,
            cellWidthPixels: Int, cellHeightPixels: Int,
            boundsWidth: Double, boundsHeight: Double,
            backingWidth: Double, backingHeight: Double,
            contentScaleX: Double, contentScaleY: Double,
            backingScaleFactor: Double
        ) {
            self.id = id
            self.title = title
            self.workingDirectory = workingDirectory
            self.columns = columns
            self.rows = rows
            self.focused = focused
            self.widthPixels = widthPixels
            self.heightPixels = heightPixels
            self.cellWidthPixels = cellWidthPixels
            self.cellHeightPixels = cellHeightPixels
            self.boundsWidth = boundsWidth
            self.boundsHeight = boundsHeight
            self.backingWidth = backingWidth
            self.backingHeight = backingHeight
            self.contentScaleX = contentScaleX
            self.contentScaleY = contentScaleY
            self.backingScaleFactor = backingScaleFactor
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
