import ArgumentParser
import CasperCore
import Foundation

/// The version `casper --version` reports: the packaged app's real version when
/// there is a bundle to read it from, else the compiled-in fallback.
private let casperVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    ?? casperFallbackVersion

/// The root `casper` command. Ships the domain commands (`status`, `progress`,
/// `notify`, `info`, `terminal`, `browser`, `diff`, `workspace`, `run`); `casper debug`
/// is added only in debug builds.
public struct CasperCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "casper",
        abstract: "Casper — per-worktree agent terminal workspaces.",
        // `--version` is routed to the CLI by `LaunchMode.detect`; wiring a value
        // here is what makes it print instead of erroring.
        version: casperVersion,
        subcommands: {
            var subs: [ParsableCommand.Type] = [
                StatusCommand.self, ProgressCommand.self, NotifyCommand.self, InfoCommand.self,
                TerminalCommand.self, BrowserCommand.self, DiffCommand.self,
                WorkspaceCommand.self, RunCommand.self,
            ]
            #if DEBUG
            subs.append(DebugCLICommand.self)
            #endif
            return subs
        }())

    public init() {}
}
