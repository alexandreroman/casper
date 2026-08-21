import ArgumentParser
import CasperCore

/// `casper terminal new|list|close` — open, enumerate, and close terminals in a
/// workspace.
struct TerminalCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "terminal",
        abstract: "Open, list, and close terminals in a workspace.",
        subcommands: [New.self, List.self, Close.self])

    struct New: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Open a new terminal as a split below.")

        @OptionGroup var target: WorkspaceTargetOption
        @Option(name: .long, help: "Command to run in the new terminal.") var command: String?
        @Option(
            name: .long,
            help: "Working directory for the new terminal (defaults to the workspace's worktree).")
        var workingDir: String?

        func makeCommand() throws -> ControlCommand {
            ControlCommand(
                verb: .terminalNew, workspace: try requireSelector(target),
                command: nonEmpty(command), cwd: workingDir.map(absolutePath))
        }

        func run() throws {
            let response = try sendControl(makeCommand(), retriable: false)
            guard let info = response.terminals?.first else { throw exitWithError("no terminal returned") }
            emit(TerminalNewOut(
                terminal: info.id, workspace: response.workspaceRef,
                command: nonEmpty(command), workingDir: info.cwd))
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List the terminals in a workspace.")

        @OptionGroup var target: WorkspaceTargetOption

        func makeCommand() throws -> ControlCommand {
            ControlCommand(verb: .terminalList, workspace: try requireSelector(target))
        }

        func run() throws {
            let r = try sendControl(makeCommand(), retriable: true)
            emit((r.terminals ?? []).map {
                TerminalInfoOut(terminal: $0.id, workingDir: $0.cwd)
            })
        }
    }

    struct Close: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Close a terminal by id.")

        @Argument(help: "The id of the terminal to close.") var id: String
        @OptionGroup var target: WorkspaceTargetOption

        func makeCommand() throws -> ControlCommand {
            ControlCommand(verb: .terminalClose, workspace: try requireSelector(target), target: id)
        }

        func run() throws {
            let r = try sendControl(makeCommand(), retriable: false)
            emit(TerminalCloseOut(terminal: id, workspace: r.workspaceRef))
        }
    }
}
