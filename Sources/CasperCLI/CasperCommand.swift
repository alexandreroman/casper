import ArgumentParser

/// The root `casper` command. Ships the `casper hooks` family; `casper debug`
/// is added only in debug builds.
public struct CasperCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "casper",
        abstract: "Casper — per-worktree agent terminal workspaces.",
        subcommands: {
            var subs: [ParsableCommand.Type] = [HooksCommand.self]
            #if DEBUG
            subs.append(DebugCLICommand.self)
            #endif
            return subs
        }())

    public init() {}
}
