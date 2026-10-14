import ArgumentParser
import CasperCore
import Foundation

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
        @Option(name: .long, parsing: .unconditional, help: "Command to run in the new terminal.")
        var command: String?
        @Option(
            name: .long,
            help: "Working directory for the new terminal (defaults to the workspace's worktree).")
        var workingDir: String?

        func makeCommand() throws -> ControlCommand {
            let selector = try requireSelector(target)
            let cwd = try nonEmpty(workingDir).map { try Self.requireDirectory(absolutePath($0)) }
            return ControlCommand(
                verb: .terminalNew, workspace: selector, command: nonEmpty(command), cwd: cwd)
        }

        /// libghostty ignores a failed `chdir` and starts the shell in the app's
        /// own directory, so a missing `--working-dir` must fail here or the verb
        /// would succeed and report a directory the terminal is not in.
        private static func requireDirectory(_ path: String) throws -> String {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                throw exitWithError("working directory '\(path)' does not exist")
            }
            guard isDirectory.boolValue else {
                throw exitWithError("working directory '\(path)' is not a directory")
            }
            return path
        }

        func run() throws {
            let response = try sendControl(makeCommand(), retriable: false)
            let info = try requireFirst(response.terminals, "terminal")
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
            let id = try requireNonEmpty(self.id, "terminal id")
            return ControlCommand(verb: .terminalClose, workspace: try requireSelector(target), target: id)
        }

        func run() throws {
            let r = try sendControl(makeCommand(), retriable: false)
            emit(TerminalCloseOut(terminal: id, workspace: r.workspaceRef))
        }
    }
}
