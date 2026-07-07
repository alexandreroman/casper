import ArgumentParser
import CasperCore
import Foundation

/// `casper browser open <url>` / `casper browser close` — open a URL in, or
/// collapse, the workspace's browser panel.
struct BrowserCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "browser",
        abstract: "Open or close a workspace's browser panel.",
        subcommands: [Open.self, Close.self])

    struct Open: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Open a URL in the browser panel.")

        @Argument(help: "URL to open.")
        var url: String
        @OptionGroup var target: WorkspaceTargetOption

        func makeCommand() throws -> ControlCommand {
            guard !url.isEmpty else { throw exitWithError("missing url") }
            guard let parsed = URL(string: url), parsed.scheme != nil, parsed.host != nil else {
                throw exitWithError("invalid url '\(url)' (expected an absolute URL like https://example.com)")
            }
            let selector = try requireSelector(target)
            return ControlCommand(verb: .browserOpen, workspace: selector, url: url)
        }

        func run() throws {
            let response = try sendControl(makeCommand(), retriable: false)
            emit(WorkspaceRefOut(workspace: response.workspace ?? ""))
        }
    }

    struct Close: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Collapse the inspector if the browser panel is showing.")

        @OptionGroup var target: WorkspaceTargetOption

        func makeCommand() throws -> ControlCommand {
            ControlCommand(verb: .browserClose, workspace: try requireSelector(target))
        }

        func run() throws {
            let response = try sendControl(makeCommand(), retriable: false)
            emit(WorkspaceRefOut(workspace: response.workspace ?? ""))
        }
    }
}
