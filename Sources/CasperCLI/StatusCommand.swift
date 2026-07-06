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
            abstract: "Set the agent state (running|waiting|done|error|idle).")

        @Argument(help: "Agent state: running, waiting, done, error, or idle.")
        var state: String
        @OptionGroup var target: WorkspaceTargetOption

        func makeCommand() throws -> ControlCommand {
            guard let parsed = AgentState(rawValue: state), parsed != .unknown else {
                throw exitWithError("invalid state '\(state)' (expected running|waiting|done|error|idle)")
            }
            let selector = try requireSelector(target)
            return ControlCommand(verb: .statusSet, workspace: selector, state: parsed.rawValue)
        }

        func run() throws { _ = try sendControl(makeCommand(), retriable: false) }
    }
}
