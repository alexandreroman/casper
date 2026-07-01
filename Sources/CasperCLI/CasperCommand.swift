import ArgumentParser

/// The root `casper` command. v1 ships the `casper hooks` family (`setup` +
/// `feed`); `open` and `worktree` land in a later plan.
public struct CasperCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "casper",
        abstract: "Casper — per-worktree agent terminal workspaces.",
        subcommands: [HooksCommand.self])

    public init() {}
}
