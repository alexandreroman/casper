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

public indirect enum LayoutNode: Codable, Equatable, Sendable {
    case split(orientation: Orientation, children: [LayoutNode], ratios: [Double])
    case tabGroup(surfaces: [Surface], activeIndex: Int)

    public enum Orientation: String, Codable, Sendable {
        case horizontal, vertical
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
