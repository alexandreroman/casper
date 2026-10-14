#if DEBUG
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
        case mouseMove
        case memory
    }

    public var verb: Verb
    public var text: String?        // sendText / sendKeys / sendKey / sendAction payload
    public var enter: Bool?         // sendText: submit the line via a Return key event
    public var mods: [String]?      // sendKey: modifier names
    public var scrollback: Bool?    // readText: full screen vs. viewport
    public var path: String?        // screenshot: output file path
    public var target: String?      // surface id to address (nil = focused/first)
    public var x: Double?           // mouseMove: position in libghostty top-left coordinates
    public var y: Double?           // mouseMove: position in libghostty top-left coordinates

    public init(
        verb: Verb, text: String? = nil, enter: Bool? = nil, mods: [String]? = nil,
        scrollback: Bool? = nil, path: String? = nil, target: String? = nil,
        x: Double? = nil, y: Double? = nil
    ) {
        self.verb = verb
        self.text = text
        self.enter = enter
        self.mods = mods
        self.scrollback = scrollback
        self.path = path
        self.target = target
        self.x = x
        self.y = y
    }
}

/// Snapshot of the app's observable UI state, returned by `dumpState`.
public struct DebugState: Codable, Equatable, Sendable {
    /// Raw geometry of one surface, for diagnosing content-scale double-counting:
    /// libghostty's `ghostty_surface_size` readback plus the hosting AppKit view's
    /// own metrics.
    public struct Geometry: Codable, Equatable, Sendable {
        public var columns: Int
        public var rows: Int
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
            columns: Int, rows: Int,
            widthPixels: Int, heightPixels: Int,
            cellWidthPixels: Int, cellHeightPixels: Int,
            boundsWidth: Double, boundsHeight: Double,
            backingWidth: Double, backingHeight: Double,
            contentScaleX: Double, contentScaleY: Double,
            backingScaleFactor: Double
        ) {
            self.columns = columns
            self.rows = rows
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

        /// All-zero geometry, used when no live surface backs the view yet.
        public static let zero = Geometry(
            columns: 0, rows: 0,
            widthPixels: 0, heightPixels: 0,
            cellWidthPixels: 0, cellHeightPixels: 0,
            boundsWidth: 0, boundsHeight: 0,
            backingWidth: 0, backingHeight: 0,
            contentScaleX: 0, contentScaleY: 0,
            backingScaleFactor: 0)
    }

    /// One surface as `dump-state` reports it. On the wire the geometry fields sit
    /// flat beside the identity fields (`"columns"`, `"cellWidthPixels"`, …), not
    /// nested under a `"geometry"` key: the `debug-casper` skill reads them by name.
    public struct Surface: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var workingDirectory: String?
        public var focused: Bool
        public var geometry: Geometry
        // Agent-state detection, reported so a detection change can be verified against the
        // running app rather than by reading the sidebar by eye. `agentState` is detection's
        // output; `oscTitle` and `progressReport` are two of its three inputs — the third, the
        // viewport text, is already reachable through the `readText` verb.

        /// The workspace's current `AgentState.rawValue` — exactly what the sidebar status icon
        /// renders, i.e. what detection concluded.
        public var agentState: String?
        /// The surface's latest OSC window title, one of detection's inputs. Nil until a title
        /// has arrived.
        public var oscTitle: String?
        /// The surface's latest OSC 9;4 progress state as `AgentProgressState.rawValue`, another
        /// of detection's inputs. Nil until a progress report has arrived.
        public var progressReport: String?

        public init(
            id: String, title: String, workingDirectory: String?, focused: Bool,
            geometry: Geometry,
            agentState: String? = nil, oscTitle: String? = nil, progressReport: String? = nil
        ) {
            self.id = id
            self.title = title
            self.workingDirectory = workingDirectory
            self.focused = focused
            self.geometry = geometry
            self.agentState = agentState
            self.oscTitle = oscTitle
            self.progressReport = progressReport
        }

        // The keys this type writes itself; `Geometry` writes its own into the same
        // keyed container, which is what keeps the wire form flat.
        private enum CodingKeys: String, CodingKey {
            case id, title, workingDirectory, focused, agentState, oscTitle, progressReport
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            title = try container.decode(String.self, forKey: .title)
            workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
            focused = try container.decode(Bool.self, forKey: .focused)
            geometry = try Geometry(from: decoder)
            agentState = try container.decodeIfPresent(String.self, forKey: .agentState)
            oscTitle = try container.decodeIfPresent(String.self, forKey: .oscTitle)
            progressReport = try container.decodeIfPresent(String.self, forKey: .progressReport)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(title, forKey: .title)
            try container.encodeIfPresent(workingDirectory, forKey: .workingDirectory)
            try container.encode(focused, forKey: .focused)
            try geometry.encode(to: encoder)
            try container.encodeIfPresent(agentState, forKey: .agentState)
            try container.encodeIfPresent(oscTitle, forKey: .oscTitle)
            try container.encodeIfPresent(progressReport, forKey: .progressReport)
        }
    }

    public var surfaces: [Surface]

    public init(surfaces: [Surface]) { self.surfaces = surfaces }
}

/// Process memory plus the live-object census, returned by `memory`. Together
/// they separate "the process grew" from "these objects were never released",
/// which is what tells a real leak apart from allocator noise.
public struct DebugMemory: Codable, Equatable, Sendable {
    /// `phys_footprint` — the number Activity Monitor shows as "Memory".
    public var footprintBytes: Int
    /// `resident_size` — physical pages currently mapped in.
    public var residentBytes: Int
    /// `ledger_phys_footprint_peak`, or 0 when the kernel does not report it.
    public var peakFootprintBytes: Int
    public var liveObjects: [LiveObjectCensus.Entry]
    /// Named sizes of the app's per-id caches and collections, e.g. "surfaceViews": 3.
    public var counters: [String: Int]

    public init(
        footprintBytes: Int, residentBytes: Int, peakFootprintBytes: Int,
        liveObjects: [LiveObjectCensus.Entry] = [], counters: [String: Int] = [:]
    ) {
        self.footprintBytes = footprintBytes
        self.residentBytes = residentBytes
        self.peakFootprintBytes = peakFootprintBytes
        self.liveObjects = liveObjects
        self.counters = counters
    }
}

/// The reply to a `DebugCommand`. `text` carries read-text output or a
/// screenshot path; `state` carries a `dumpState` snapshot; `memory` carries a
/// `memory` snapshot; `error` is set when `ok` is false.
public struct DebugResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var text: String?
    public var state: DebugState?
    public var memory: DebugMemory?
    public var error: String?

    public init(
        ok: Bool, text: String? = nil, state: DebugState? = nil, memory: DebugMemory? = nil,
        error: String? = nil
    ) {
        self.ok = ok
        self.text = text
        self.state = state
        self.memory = memory
        self.error = error
    }

    public static func success(
        text: String? = nil, state: DebugState? = nil, memory: DebugMemory? = nil
    ) -> DebugResponse {
        DebugResponse(ok: true, text: text, state: state, memory: memory)
    }

    public static func failure(_ message: String) -> DebugResponse {
        DebugResponse(ok: false, error: message)
    }
}
#endif
