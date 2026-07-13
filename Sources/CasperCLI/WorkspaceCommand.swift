import ArgumentParser
import CasperCore
import Foundation

/// `casper workspace list|current|new` — enumerate, identify, and create workspaces.
struct WorkspaceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "workspace",
        abstract: "List, identify, create, and delete workspaces.",
        subcommands: [List.self, Current.self, New.self, Delete.self])

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List all workspaces.")

        func makeCommand() -> ControlCommand { ControlCommand(verb: .workspaceList) }

        func run() throws {
            let response = try sendControl(makeCommand(), retriable: true)
            emit(response.workspaces?.map {
                WorkspaceOut(
                    workspace: $0.id, name: $0.name,
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
            emit(CurrentOut(
                workspace: match?.id ?? id, name: match?.name,
                branch: (match?.branch).flatMap { $0.isEmpty ? nil : $0 }, path: match?.path))
        }
    }

    struct New: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create a new Git worktree workspace.")
        @Argument(help: "New branch name for the worktree.") var branch: String
        @Option(name: .long, help: "Base ref to fork from (defaults to the space's base branch).")
        var base: String?
        @Option(name: .long, help: "Command to run in the workspace's initial terminal.") var command: String?
        @OptionGroup var target: WorkspaceTargetOption

        func makeCommand() throws -> ControlCommand {
            let selector = try requireSelector(target)
            return ControlCommand(
                verb: .workspaceNew, workspace: selector, branch: branch, base: base,
                command: normalizedCommand(command))
        }

        func run() throws {
            // The app creates the worktree synchronously before replying (git
            // worktree add + branch + `.casper.json` copyPatterns file copy), which
            // can exceed the default 5s on a large repo or broad copyPatterns.
            // Allow well beyond it — mirroring `workspace delete` — so a slow but
            // successful creation is not misreported as a client-side timeout.
            let response = try sendControl(makeCommand(), retriable: false, timeout: 35)
            guard let info = response.workspaces?.first else {
                throw exitWithError("no workspace returned")
            }
            emit(WorkspaceNewOut(
                workspace: info.id, name: info.name,
                branch: info.branch.isEmpty ? nil : info.branch, path: info.path,
                command: normalizedCommand(command)))
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
            // The app runs the repo's `teardown` hook (up to ~30s — see
            // AppModel.teardownTimeout) before replying, so allow well beyond the
            // default 5s or a slow teardown would be misreported as a client-side
            // timeout even though the deletion succeeds.
            let response = try sendControl(makeCommand(), retriable: false, timeout: 35)
            emit(WorkspaceRefOut(workspace: response.workspace ?? ""))
        }
    }
}
