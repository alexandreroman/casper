import ArgumentParser
import CasperCore

/// `casper diff open [<file>]` / `casper diff close` — open, or collapse, the
/// diff view of a workspace.
struct DiffCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diff",
        abstract: "Open or close the diff view of a workspace.",
        subcommands: [Open.self, Close.self])

    struct Open: WorkspaceRefCommand {
        static let configuration = CommandConfiguration(abstract: "Open the diff view.")

        @Argument(help: "File path to scroll the diff view to (optional).")
        var file: String?
        @OptionGroup var target: WorkspaceTargetOption

        func makeCommand() throws -> ControlCommand {
            ControlCommand(
                verb: .diffOpen, workspace: try requireSelector(target),
                target: normalizedCommand(file))
        }
    }

    struct Close: WorkspaceRefCommand {
        static let configuration = CommandConfiguration(
            abstract: "Collapse the inspector if the diff view is showing.")

        @OptionGroup var target: WorkspaceTargetOption

        func makeCommand() throws -> ControlCommand {
            ControlCommand(verb: .diffClose, workspace: try requireSelector(target))
        }
    }
}
