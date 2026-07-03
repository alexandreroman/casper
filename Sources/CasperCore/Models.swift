import Foundation

public enum AgentState: String, Codable, Sendable {
    case idle, running, waiting, done, error, unknown
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
        case terminal(cwd: String, command: String?)
        case browser(url: URL)
        case diff(againstHead: Bool)
    }

    public var id: UUID
    public var kind: Kind

    public init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }
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
            self = .split(
                orientation: try c.decode(Orientation.self, forKey: .orientation),
                children: try c.decode([LayoutNode].self, forKey: .children),
                ratios: try c.decode([Double].self, forKey: .ratios))
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

    static func evenRatios(_ n: Int) -> [Double] {
        Array(repeating: 1.0 / Double(n), count: n)
    }
}

public enum WorkspaceKind: String, Codable, Sendable {
    case primary, linked
}

public struct Workspace: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var worktreePath: String
    public var branch: String
    public var agentState: AgentState
    public var todos: [Todo]
    public var pendingNotification: Bool
    public var portBase: Int
    public var layout: LayoutNode
    public var kind: WorkspaceKind
    public var baseBranch: String?

    public init(
        id: UUID = UUID(),
        name: String,
        worktreePath: String,
        branch: String,
        agentState: AgentState = .idle,
        todos: [Todo] = [],
        pendingNotification: Bool = false,
        portBase: Int,
        layout: LayoutNode,
        kind: WorkspaceKind = .primary,
        baseBranch: String? = nil
    ) {
        self.id = id
        self.name = name
        self.worktreePath = worktreePath
        self.branch = branch
        self.agentState = agentState
        self.todos = todos
        self.pendingNotification = pendingNotification
        self.portBase = portBase
        self.layout = layout
        self.kind = kind
        self.baseBranch = baseBranch
    }
}

public struct Space: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var folderPath: String
    public var isGitRepo: Bool
    public var workspaces: [Workspace]

    public init(
        id: UUID = UUID(),
        name: String,
        folderPath: String,
        isGitRepo: Bool,
        workspaces: [Workspace]
    ) {
        self.id = id
        self.name = name
        self.folderPath = folderPath
        self.isGitRepo = isGitRepo
        self.workspaces = workspaces
    }
}

public struct Session: Codable, Equatable, Sendable {
    public var spaces: [Space]
    public init(spaces: [Space] = []) {
        self.spaces = spaces
    }
}
