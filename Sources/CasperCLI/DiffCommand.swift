import ArgumentParser
import CasperCore

/// `casper diff show [<target>]` — show the diff view for a workspace.
struct DiffCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diff",
        abstract: "Show the diff view of a workspace.",
        subcommands: [Show.self])

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show the diff view.")

        @Argument(help: "Diff target (reserved; defaults to working tree vs HEAD).")
        var target: String?
        @OptionGroup var workspaceTarget: WorkspaceTargetOption

        func makeCommand() throws -> ControlCommand {
            ControlCommand(
                verb: .diffShow, workspace: try requireSelector(workspaceTarget), target: target)
        }

        func run() throws {
            let response = try sendControl(makeCommand(), retriable: false)
            emit(DiffOut(view: "diff", workspace: response.workspace ?? ""))
        }
    }
}
