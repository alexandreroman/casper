import ArgumentParser
import CasperCore

/// `casper diff open [<file>]` / `casper diff close` — open, or collapse, the
/// diff view of a workspace.
struct DiffCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diff",
        abstract: "Open or close the diff view of a workspace.",
        subcommands: [Open.self, Close.self])

    struct Open: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Open the diff view.")

        @Argument(help: "File path to scroll the diff view to (optional).")
        var file: String?
        @OptionGroup var workspaceTarget: WorkspaceTargetOption

        func makeCommand() throws -> ControlCommand {
            ControlCommand(
                verb: .diffOpen, workspace: try requireSelector(workspaceTarget), target: file)
        }

        func run() throws {
            let response = try sendControl(makeCommand(), retriable: false)
            emit(WorkspaceRefOut(workspace: response.workspace ?? ""))
        }
    }

    struct Close: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Collapse the inspector if the diff view is showing.")

        @OptionGroup var workspaceTarget: WorkspaceTargetOption

        func makeCommand() throws -> ControlCommand {
            ControlCommand(verb: .diffClose, workspace: try requireSelector(workspaceTarget))
        }

        func run() throws {
            let response = try sendControl(makeCommand(), retriable: false)
            emit(WorkspaceRefOut(workspace: response.workspace ?? ""))
        }
    }
}
