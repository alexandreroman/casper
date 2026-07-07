import ArgumentParser
import CasperCore
import Foundation

/// `casper workspace list|current|new` — enumerate, identify, and create workspaces.
struct WorkspaceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "workspace",
        abstract: "List, identify, and create workspaces.",
        subcommands: [List.self, Current.self, New.self, Delete.self])

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List all workspaces.")

        func makeCommand() -> ControlCommand { ControlCommand(verb: .workspaceList) }

        func run() throws {
            let response = try sendControl(makeCommand(), retriable: true)
            emit(response.workspaces?.map {
                WorkspaceOut(
                    id: $0.id, name: $0.name,
                    branch: $0.branch.isEmpty ? nil : $0.branch, path: $0.path)
            } ?? [])
        }
    }

    struct Current: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print the current workspace id ($CASPER_WORKSPACE_ID).")

        func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
            environment["CASPER_WORKSPACE_ID"]
        }

        func run() throws {
            guard let id = resolve() else {
                throw exitWithError("not inside a Casper terminal (CASPER_WORKSPACE_ID unset)")
            }
            // Resolve the path via the control channel: a Casper terminal always has
            // the app running, so the standard "Casper is not running" error is fine
            // if the socket is unset/unreachable.
            let response = try sendControl(ControlCommand(verb: .workspaceList), retriable: true)
            let match = response.workspaces?.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
            emit(CurrentOut(workspace: match?.id ?? id, path: match?.path))
        }
    }

    struct New: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create a new Git worktree workspace.")
        @Option(name: .long, help: "New branch name for the worktree.") var branch: String = ""
        @Option(name: .long, help: "Base ref to fork from (defaults to the space's base branch).")
        var base: String?
        @Option(name: .long, help: "Command to run in the workspace's initial terminal.") var command: String?
        @OptionGroup var target: WorkspaceTargetOption

        /// The command normalized so an empty string means "no command", mirroring
        /// the `--branch` empty-check.
        private var effectiveCommand: String? {
            command.flatMap { $0.isEmpty ? nil : $0 }
        }

        func makeCommand() throws -> ControlCommand {
            guard !branch.isEmpty else { throw exitWithError("missing --branch") }
            let selector = try requireSelector(target)
            return ControlCommand(
                verb: .workspaceNew, workspace: selector, branch: branch, base: base,
                command: effectiveCommand)
        }

        func run() throws {
            let response = try sendControl(makeCommand(), retriable: false)
            guard let info = response.workspaces?.first else {
                throw exitWithError("no workspace returned")
            }
            emit(WorkspaceNewOut(
                workspace: info.id, name: info.name,
                branch: info.branch.isEmpty ? nil : info.branch, path: info.path,
                command: effectiveCommand))
        }
    }

    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete a workspace: remove its worktree folder, its branch, and its UI entry.")
        @OptionGroup var target: WorkspaceTargetOption
        func makeCommand() throws -> ControlCommand {
            ControlCommand(verb: .workspaceDelete, workspace: try requireSelector(target))
        }
        func run() throws {
            let response = try sendControl(makeCommand(), retriable: false)
            emit(WorkspaceRefOut(workspace: response.workspace ?? ""))
        }
    }
}
