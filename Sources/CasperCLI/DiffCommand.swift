import ArgumentParser
import CasperCore

/// `casper diff open [<file>]` — open the diff view for a workspace.
struct DiffCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diff",
        abstract: "Open the diff view of a workspace.",
        subcommands: [Open.self])

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
}
