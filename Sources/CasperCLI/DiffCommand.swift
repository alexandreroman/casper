import ArgumentParser
import CasperCore
import Foundation

/// `casper diff open [<file>]` / `casper diff close` — open, or collapse, the
/// diff view of a workspace.
struct DiffCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diff",
        abstract: "Open or close the diff view of a workspace.",
        subcommands: [Open.self, Close.self])

    struct Open: WorkspaceRefCommand {
        static let configuration = CommandConfiguration(abstract: "Open the diff view.")

        @Argument(help: "File to scroll to, relative to the workspace's worktree root (or absolute).")
        var file: String?
        @OptionGroup var target: WorkspaceTargetOption
        // A file deleted from the worktree is checked against a full diff read before
        // the app replies, which on a large worktree can outlast the default 5 s: the
        // diff would open while the CLI reported a timeout.
        var commandTimeout: TimeInterval { WorkspaceCommand.slowVerbTimeout }

        func makeCommand() throws -> ControlCommand {
            ControlCommand(
                verb: .diffOpen, workspace: try requireSelector(target),
                target: nonEmpty(file))
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
