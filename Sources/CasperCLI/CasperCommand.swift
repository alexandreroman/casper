import ArgumentParser
import CasperAgents

/// The root `casper` command. Ships the domain commands (`status`, `progress`,
/// `notify`, `terminal`, `browser`, `diff`, `workspace`); `casper debug` is
/// added only in debug builds.
public struct CasperCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "casper",
        abstract: "Casper — per-worktree agent terminal workspaces.",
        // Wired to the CasperAgents module version so `--version` (routed to the
        // CLI by `LaunchMode.detect`) prints instead of erroring.
        version: casperAgentsVersion,
        subcommands: {
            var subs: [ParsableCommand.Type] = [
                StatusCommand.self, ProgressCommand.self, NotifyCommand.self,
                TerminalCommand.self, BrowserCommand.self, DiffCommand.self,
                WorkspaceCommand.self,
            ]
            #if DEBUG
            subs.append(DebugCLICommand.self)
            #endif
            return subs
        }())

    public init() {}
}
