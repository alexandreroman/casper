import ArgumentParser
import CasperCore

/// `casper terminal new` — open a new terminal as a split to the right.
struct TerminalCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "terminal",
        abstract: "Open terminals in a workspace.",
        subcommands: [New.self])

    struct New: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Open a new terminal as a split to the right.")

        @OptionGroup var target: WorkspaceTargetOption
        @Option(name: .long, help: "Command to run in the new terminal.") var command: String?
        @Option(name: .long, help: "Working directory for the new terminal (defaults to the workspace's worktree).")
        var cwd: String?

        func makeCommand() throws -> ControlCommand {
            ControlCommand(
                verb: .terminalNew, workspace: try requireSelector(target),
                command: command, cwd: cwd)
        }

        func run() throws {
            let r = try sendControl(makeCommand(), retriable: false)
            emit(TerminalNewOut(workspace: r.workspace ?? "", command: command, cwd: cwd))
        }
    }
}
