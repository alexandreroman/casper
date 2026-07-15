import Foundation

public enum AgentState: String, Codable, Sendable, CaseIterable {
    case working, blocked, idle, done, unknown, error
}

public enum TodoStatus: String, Codable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed
}

public struct Todo: Codable, Equatable, Sendable {
    public var content: String
    public var status: TodoStatus
    public init(content: String, status: TodoStatus) {
        self.content = content
        self.status = status
    }
}

public struct Surface: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: Codable, Equatable, Sendable {
        case terminal(cwd: String)
        case browser(url: URL)
    }

    public var id: UUID
    public var kind: Kind
    /// The terminal's live font size, captured after a runtime Cmd+/Cmd-/Cmd0
    /// change; `nil` means "not customized — use libghostty's own default."
    /// Only meaningful for `.terminal` surfaces; ignored for `.browser`.
    public var fontSize: Float?

    public init(id: UUID = UUID(), kind: Kind, fontSize: Float? = nil) {
        self.id = id
        self.kind = kind
        self.fontSize = fontSize
    }

    // Full case set is required once `init(from:)` is hand-rolled; case names
    // match the property names so the synthesized `encode(to:)` keeps the same
    // on-disk keys.
    private enum CodingKeys: String, CodingKey { case id, kind, fontSize }

    /// Decodes `fontSize` as optional so legacy `session.json` files (written
    /// before font size was persisted) default it to nil, leaving that
    /// terminal at libghostty's own default — unchanged from today's
    /// behavior. `encode(to:)` stays synthesized, keeping the on-disk shape
    /// stable and forward-writing the new field.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.kind = try c.decode(Kind.self, forKey: .kind)
        self.fontSize = try c.decodeIfPresent(Float.self, forKey: .fontSize)
    }
}

extension Surface {
    /// A terminal surface rooted at `cwd`.
    public static func terminal(cwd: String) -> Surface {
        Surface(kind: .terminal(cwd: cwd))
    }

    /// A browser surface showing the blank start page.
    public static func blankBrowser() -> Surface {
        Surface(kind: .browser(url: .aboutBlank))
    }
}

extension URL {
    /// The blank page shown by a freshly-created browser surface.
    public static let aboutBlank = URL(string: "about:blank")!
}

public indirect enum LayoutNode: Equatable, Sendable {
    case split(orientation: Orientation, children: [LayoutNode], ratios: [Double])
    case leaf(Surface)

    public enum Orientation: String, Codable, Sendable {
        case horizontal, vertical
    }
}

extension LayoutNode: Codable {
    private enum CodingKeys: String, CodingKey { case split, leaf, tabGroup }
    private enum SplitKeys: String, CodingKey { case orientation, children, ratios }
    private enum LeafKeys: String, CodingKey { case _0 }
    private enum TabGroupKeys: String, CodingKey { case surfaces, activeIndex }

    /// Decodes the current `split`/`leaf` shapes, and migrates the legacy
    /// `tabGroup` shape (from older `session.json`) by folding each surface into
    /// its own leaf: 1 surface → a leaf, N → an even horizontal split of leaves.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.split) {
            let c = try container.nestedContainer(keyedBy: SplitKeys.self, forKey: .split)
            let orientation = try c.decode(Orientation.self, forKey: .orientation)
            let children = try c.decode([LayoutNode].self, forKey: .children)
            let ratios = try c.decode([Double].self, forKey: .ratios)
            // Reject inconsistent splits so a corrupt `session.json` self-heals via
            // SessionStore rather than decoding into a node that later traps in
            // `LayoutTree.closeSurface` (`ratios.remove(at:)` index-out-of-range).
            guard children.count >= 2 else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "split must have at least 2 children, found \(children.count)"))
            }
            guard ratios.count == children.count else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription:
                        "split ratios count (\(ratios.count)) must equal children count (\(children.count))"))
            }
            self = .split(orientation: orientation, children: children, ratios: ratios)
        } else if container.contains(.leaf) {
            let c = try container.nestedContainer(keyedBy: LeafKeys.self, forKey: .leaf)
            self = .leaf(try c.decode(Surface.self, forKey: ._0))
        } else if container.contains(.tabGroup) {
            let c = try container.nestedContainer(keyedBy: TabGroupKeys.self, forKey: .tabGroup)
            let surfaces = try c.decode([Surface].self, forKey: .surfaces)
            switch surfaces.count {
            case 0:
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "legacy tabGroup has no surfaces"))
            case 1:
                self = .leaf(surfaces[0])
            default:
                self = .split(
                    orientation: .horizontal,
                    children: surfaces.map { .leaf($0) },
                    ratios: LayoutNode.evenRatios(surfaces.count))
            }
        } else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "unrecognized LayoutNode shape"))
        }
    }

    /// Emits `split`/`leaf` in the same shape Swift's synthesized enum coder
    /// would, so encode/decode round-trips stay stable.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .split(let orientation, let children, let ratios):
            var c = container.nestedContainer(keyedBy: SplitKeys.self, forKey: .split)
            try c.encode(orientation, forKey: .orientation)
            try c.encode(children, forKey: .children)
            try c.encode(ratios, forKey: .ratios)
        case .leaf(let surface):
            var c = container.nestedContainer(keyedBy: LeafKeys.self, forKey: .leaf)
            try c.encode(surface, forKey: ._0)
        }
    }

    public static func evenRatios(_ n: Int) -> [Double] {
        Array(repeating: 1.0 / Double(n), count: n)
    }
}

public enum WorkspaceKind: String, Codable, Sendable {
    case primary, linked
}

public enum InspectorTab: String, Codable, Sendable {
    case browser, diff
}

/// Per-workspace state for the right inspector panel: whether it's collapsed,
/// which tab is active, and the dedicated browser `Surface` (invariant: its
/// `kind` is `.browser`). A full `Surface` — not just a URL — so the panel
/// browser reuses `AppModel`'s surface-view and coordinator caches, keyed by a
/// stable `Surface.id` that survives workspace switches and collapse/expand.
public struct InspectorState: Codable, Equatable, Sendable {
    /// Bounds for the user-resizable panel width, in points. Single source of
    /// truth shared by the SwiftUI `.inspectorColumnWidth(...)` call and the
    /// model's clamping, so the two never drift apart.
    ///
    /// `defaultWidth` is sized so the diff view (`DiffLineRow` in `DiffSurfaceView.swift`) can show ~80 columns of
    /// code content without wrapping. Budget, in points, of one diff row at its 14pt monospaced font
    /// (SF Mono advance ≈ 8.65pt/char):
    /// - code column: 80 content columns + 1 diff-marker prefix = 81 cells × 8.65 ≈ 701
    /// - gutter: budgeted for 4-digit line numbers (`maxDigits*9 + 12` = 48)
    /// - leading accent stripe (3) + gutter↔code spacing (8) = 11
    /// - ~16 slack for a legacy always-on vertical scroller
    /// Total ≈ 780, comfortably within min/max.
    public static let minWidth: Double = 240
    public static let defaultWidth: Double = 780
    public static let maxWidth: Double = 1400

    public var collapsed: Bool
    public var tab: InspectorTab
    public var browser: Surface
    public var width: Double

    public init(
        collapsed: Bool = true,
        tab: InspectorTab = .diff,
        browser: Surface = Surface.blankBrowser(),
        width: Double = InspectorState.defaultWidth
    ) {
        self.collapsed = collapsed
        self.tab = tab
        self.browser = browser
        self.width = width
    }

    // Full case set is required once `init(from:)` is hand-rolled; case names
    // match the property names so the synthesized `encode(to:)` keeps the same
    // on-disk keys.
    private enum CodingKeys: String, CodingKey {
        case collapsed, tab, browser, width
    }

    /// Decodes every current field normally and defaults `width` when it's
    /// absent, so legacy `session.json` files (written before the panel width
    /// was persisted) load with the default width. `encode(to:)` stays
    /// synthesized, keeping the on-disk shape stable and forward-writing the
    /// new field.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.collapsed = try container.decode(Bool.self, forKey: .collapsed)
        self.tab = try container.decode(InspectorTab.self, forKey: .tab)
        self.browser = try container.decode(Surface.self, forKey: .browser)
        self.width = try container.decodeIfPresent(Double.self, forKey: .width)
            ?? Self.defaultWidth
    }
}

public enum EditorKind: String, Codable, CaseIterable, Sendable {
    case vscode
    case intellijIdea
    case xcode

    /// Priority order used both as the dropdown's display order and as the
    /// fallback when a workspace has no `lastUsedEditor` yet.
    public static let priorityOrder: [EditorKind] = [.vscode, .intellijIdea, .xcode]

    public var cliCommand: String {
        switch self {
        case .vscode: "code"
        case .intellijIdea: "idea"
        case .xcode: "xed"
        }
    }

    /// Candidate bundle identifiers, most-specific first. IntelliJ IDEA ships
    /// two distinct bundle IDs depending on edition (Ultimate vs. Community);
    /// the others have exactly one.
    public var bundleIdentifiers: [String] {
        switch self {
        case .vscode: ["com.microsoft.VSCode"]
        case .intellijIdea: ["com.jetbrains.intellij", "com.jetbrains.intellij.ce"]
        case .xcode: ["com.apple.dt.Xcode"]
        }
    }

    public var displayName: String {
        switch self {
        case .vscode: "Visual Studio Code"
        case .intellijIdea: "IntelliJ IDEA"
        case .xcode: "Xcode"
        }
    }
}

public struct Workspace: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var worktreePath: String
    public var branch: String
    public var agentState: AgentState
    public var todos: [Todo]
    public var pendingNotification: Bool
    public var pendingNotificationMessage: String?
    public var portBase: Int
    public var layout: LayoutNode
    public var kind: WorkspaceKind
    public var baseBranch: String?
    public var inspector: InspectorState
    public var lastUsedEditor: EditorKind?
    public var lastUsedScript: String?

    public init(
        id: UUID = UUID(),
        name: String,
        worktreePath: String,
        branch: String,
        agentState: AgentState = .idle,
        todos: [Todo] = [],
        pendingNotification: Bool = false,
        pendingNotificationMessage: String? = nil,
        portBase: Int,
        layout: LayoutNode,
        kind: WorkspaceKind = .primary,
        baseBranch: String? = nil,
        inspector: InspectorState = InspectorState(),
        lastUsedEditor: EditorKind? = nil,
        lastUsedScript: String? = nil
    ) {
        self.id = id
        self.name = name
        self.worktreePath = worktreePath
        self.branch = branch
        self.agentState = agentState
        self.todos = todos
        self.pendingNotification = pendingNotification
        self.pendingNotificationMessage = pendingNotificationMessage
        self.portBase = portBase
        self.layout = layout
        self.kind = kind
        self.baseBranch = baseBranch
        self.inspector = inspector
        self.lastUsedEditor = lastUsedEditor
        self.lastUsedScript = lastUsedScript
    }

    // Full case set required now that both `init(from:)` and `encode(to:)` are
    // hand-rolled; case names match the property names so the on-disk keys stay
    // stable. The four transient cases (agentState, todos, pendingNotification,
    // pendingNotificationMessage) remain listed but are neither read nor written — see
    // the coders below.
    private enum CodingKeys: String, CodingKey {
        case id, name, worktreePath, branch, agentState, todos
        case pendingNotification, pendingNotificationMessage
        case portBase, layout, kind, baseBranch, inspector, lastUsedEditor, lastUsedScript
    }

    /// Encodes every persisted field, deliberately omitting the four transient
    /// runtime fields (`agentState`, `todos`, `pendingNotification`,
    /// `pendingNotificationMessage`): they are driven by the `casper` CLI (control
    /// channel), never restored from disk.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(worktreePath, forKey: .worktreePath)
        try c.encode(branch, forKey: .branch)
        // agentState / todos / pendingNotification / pendingNotificationMessage
        // are transient runtime state — never persisted.
        try c.encode(portBase, forKey: .portBase)
        try c.encode(layout, forKey: .layout)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(baseBranch, forKey: .baseBranch)
        try c.encode(inspector, forKey: .inspector)
        try c.encodeIfPresent(lastUsedEditor, forKey: .lastUsedEditor)
        try c.encodeIfPresent(lastUsedScript, forKey: .lastUsedScript)
    }

    /// Decodes every persisted field normally and defaults `inspector` when it's
    /// absent, so legacy `session.json` files (written before the inspector
    /// existed) load with a collapsed, default inspector. The four transient
    /// runtime fields (`agentState`, `todos`, `pendingNotification`,
    /// `pendingNotificationMessage`) are never read from disk — they always reset
    /// to their defaults on load, whether the file omits them (current shape) or
    /// still carries them (legacy shape).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.worktreePath = try container.decode(String.self, forKey: .worktreePath)
        self.branch = try container.decode(String.self, forKey: .branch)
        self.agentState = .idle
        self.todos = []
        self.pendingNotification = false
        self.pendingNotificationMessage = nil
        self.portBase = try container.decode(Int.self, forKey: .portBase)
        self.layout = try container.decode(LayoutNode.self, forKey: .layout)
        self.kind = try container.decode(WorkspaceKind.self, forKey: .kind)
        self.baseBranch = try container.decodeIfPresent(String.self, forKey: .baseBranch)
        self.inspector = try container.decodeIfPresent(InspectorState.self, forKey: .inspector)
            ?? InspectorState()
        self.lastUsedEditor = try container.decodeIfPresent(EditorKind.self, forKey: .lastUsedEditor)
        self.lastUsedScript = try container.decodeIfPresent(String.self, forKey: .lastUsedScript)
    }
}

public struct Space: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var folderPath: String
    public var isGitRepo: Bool
    public var isCollapsed: Bool
    public var workspaces: [Workspace]

    public init(
        id: UUID = UUID(),
        name: String,
        folderPath: String,
        isGitRepo: Bool,
        isCollapsed: Bool = false,
        workspaces: [Workspace]
    ) {
        self.id = id
        self.name = name
        self.folderPath = folderPath
        self.isGitRepo = isGitRepo
        self.isCollapsed = isCollapsed
        self.workspaces = workspaces
    }

    // Full case set is required once `init(from:)` is hand-rolled; case names
    // match the property names so the synthesized `encode(to:)` keeps the same
    // on-disk keys.
    private enum CodingKeys: String, CodingKey {
        case id, name, folderPath, isCollapsed, workspaces
    }

    /// Decodes every persisted field normally and defaults `isCollapsed` when it's
    /// absent, so legacy `session.json` files (written before the collapse flag
    /// existed) load expanded. `encode(to:)` stays synthesized, keeping the
    /// on-disk shape stable and forward-writing new fields.
    ///
    /// `isGitRepo` is intentionally NOT persisted: it is a runtime-only flag,
    /// resolved after decoding by probing `folderPath` for Git backing. Every
    /// decoded Space therefore arrives non-Git and must be reconciled at load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.folderPath = try container.decode(String.self, forKey: .folderPath)
        self.isGitRepo = false  // runtime-only; resolved after load by probing the folder
        self.isCollapsed = try container.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
        self.workspaces = try container.decode([Workspace].self, forKey: .workspaces)
    }

    /// Workspaces in display order: the primary workspace (the repo's default
    /// branch) first, then the linked workspaces sorted by name.
    public var orderedWorkspaces: [Workspace] {
        workspaces.sorted { lhs, rhs in
            if (lhs.kind == .primary) != (rhs.kind == .primary) {
                return lhs.kind == .primary
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

public struct Session: Codable, Equatable, Sendable {
    public var spaces: [Space]
    /// The workspace selected when the session was last saved, re-selected on
    /// relaunch. Optional, so its synthesized `Codable` decodes an absent key
    /// (legacy `session.json` files) to nil.
    public var selectedWorkspaceID: UUID?
    public init(spaces: [Space] = [], selectedWorkspaceID: UUID? = nil) {
        self.spaces = spaces
        self.selectedWorkspaceID = selectedWorkspaceID
    }
}
