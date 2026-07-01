import ArgumentParser

/// `casper hooks` — Claude Code hook integration, providing a `hooks`
/// command family: `casper hooks setup` installs the hooks into a worktree,
/// and `casper hooks feed` (invoked by those installed hooks) relays events.
public struct HooksCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "hooks",
        abstract: "Set up and relay Casper's Claude Code hooks.",
        subcommands: [HooksFeedCommand.self, HooksSetupCommand.self])

    public init() {}
}
