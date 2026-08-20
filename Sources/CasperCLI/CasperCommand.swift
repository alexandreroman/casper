import ArgumentParser
import CasperAgents
import Foundation

/// The version `casper --version` reports. A packaged `Casper.app` carries the
/// real one in `CFBundleShortVersionString` (substituted by
/// `Scripts/bundle-app.sh` at packaging time); an unbundled binary — `swift run`,
/// or the executable invoked outside the app — has no Info.plist to read, so it
/// falls back to the compiled-in module version.
private let casperVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    ?? casperAgentsVersion

/// The root `casper` command. Ships the domain commands (`status`, `progress`,
/// `notify`, `info`, `terminal`, `browser`, `diff`, `workspace`); `casper debug`
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
