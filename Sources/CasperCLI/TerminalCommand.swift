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

        func makeCommand() throws -> ControlCommand {
            ControlCommand(verb: .terminalNew, workspace: try requireSelector(target))
        }

        func run() throws {
            let response = try sendControl(makeCommand(), retriable: false)
            emit(TerminalOut(terminal: Opened(opened: true), workspace: response.workspace ?? ""))
        }
    }
}
