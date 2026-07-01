import Foundation

/// The stateful, per-workspace owner of the agent state machine. It wraps the
/// pure `AgentStateReducer` over a keyed collection of workspaces and reports
/// mutations through `onChange` so a UI can react. Thread-confinement is the
/// caller's responsibility (Plan 5 drives it from the main actor).
public final class AgentStateStore {
    public private(set) var workspaces: [Workspace]

    /// Invoked with the mutated workspace after any state change.
    public var onChange: ((Workspace) -> Void)?

    public init(workspaces: [Workspace] = []) {
        self.workspaces = workspaces
    }

    public func workspace(id: UUID) -> Workspace? {
        workspaces.first { $0.id == id }
    }

    /// Apply a hook event to the identified workspace. Returns the reducer's
    /// side effect (e.g. a notification), or `nil` when there is none or the
    /// workspace is unknown.
    @discardableResult
    public func handle(
        _ event: HookEvent, workspaceId: UUID, focused: Bool
    ) -> AgentEffect? {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceId })
        else { return nil }
        let effect = AgentStateReducer.apply(
            event, to: &workspaces[index], focused: focused)
        onChange?(workspaces[index])
        return effect
    }
}
