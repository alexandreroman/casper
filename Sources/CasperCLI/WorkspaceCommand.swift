import ArgumentParser
import CasperCore
import Foundation

/// `casper workspace list|current|new` — enumerate, identify, and create workspaces.
struct WorkspaceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "workspace",
        abstract: "List, identify, and create workspaces.",
        subcommands: [List.self, Current.self, New.self])

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List all workspaces.")

        func makeCommand() -> ControlCommand { ControlCommand(verb: .workspaceList) }

        func run() throws {
            let response = try sendControl(makeCommand(), retriable: true)
            for workspace in response.workspaces ?? [] {
                print("\(workspace.id)\t\(workspace.name)\t\(workspace.branch)")
            }
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
            print(id)
        }
    }

    struct New: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create a new Git worktree workspace.")
        @Option(name: .long, help: "New branch name for the worktree.") var branch: String = ""
        @Option(name: .long, help: "Base ref to fork from (defaults to the space's base branch).")
        var base: String?
        @OptionGroup var target: WorkspaceTargetOption

        func makeCommand() throws -> ControlCommand {
            guard !branch.isEmpty else { throw exitWithError("missing --branch") }
            let selector = try requireSelector(target)
            return ControlCommand(verb: .workspaceNew, workspace: selector, branch: branch, base: base)
        }

        func run() throws {
            let response = try sendControl(makeCommand(), retriable: false)
            if let id = response.text { print(id) }
        }
    }
}
