import ArgumentParser
import CasperCore

/// Lets ArgumentParser parse, validate, and list the closed `AgentState` value
/// set natively for `status set <state>`.
extension AgentState: ExpressibleByArgument {}

/// `casper status set <state>` / `casper status get` — set and read back the
/// target workspace's agent state.
struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Report the agent state of a workspace.",
        subcommands: [Set.self, Get.self])

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Set the agent state (working|blocked|idle|done|unknown|error).")

        @Argument(help: "Agent state to set.")
        var state: AgentState
        @OptionGroup var target: WorkspaceTargetOption

        func makeCommand() throws -> ControlCommand {
            let selector = try requireSelector(target)
            return ControlCommand(verb: .statusSet, workspace: selector, state: state.rawValue)
        }

        func run() throws {
            let response = try sendControl(makeCommand(), retriable: false)
            emit(StatusOut(status: state.rawValue, workspace: response.workspaceRef))
        }
    }

    /// Reads the state back out. Exists for the agent plugin's turn-end hook,
    /// which must not overwrite a `blocked` or `error` the agent reported for
    /// itself — a verdict no hook can infer from a turn boundary.
    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Read the agent state of a workspace.")

        @OptionGroup var target: WorkspaceTargetOption

        func makeCommand() throws -> ControlCommand {
            ControlCommand(verb: .statusGet, workspace: try requireSelector(target))
        }

        func run() throws {
            let response = try sendControl(makeCommand(), retriable: true)
            emit(StatusOut(
                status: response.text ?? AgentState.unknown.rawValue,
                workspace: response.workspaceRef))
        }
    }
}
