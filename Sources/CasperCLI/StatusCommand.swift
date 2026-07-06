import ArgumentParser
import CasperCore

/// `casper status set <state>` — set the target workspace's agent state.
struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Report the agent state of a workspace.",
        subcommands: [Set.self])

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Set the agent state (working|blocked|idle|done|unknown|error).")

        @Argument(help: "Agent state: working, blocked, idle, done, unknown, or error.")
        var state: String
        @OptionGroup var target: WorkspaceTargetOption

        func makeCommand() throws -> ControlCommand {
            guard let parsed = AgentState(rawValue: state) else {
                throw exitWithError(
                    "invalid state '\(state)' (expected working|blocked|idle|done|unknown|error)")
            }
            let selector = try requireSelector(target)
            return ControlCommand(verb: .statusSet, workspace: selector, state: parsed.rawValue)
        }

        func run() throws {
            let response = try sendControl(makeCommand(), retriable: false)
            emit(StatusOut(status: state, workspace: response.workspace ?? ""))
        }
    }
}
