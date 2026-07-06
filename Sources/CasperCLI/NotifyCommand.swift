import ArgumentParser
import CasperCore

/// `casper notify [--message <str>]` — raise the workspace's attention flag
/// (sidebar dot); with `--message`, also post a macOS notification.
struct NotifyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notify",
        abstract: "Raise a workspace's attention flag (optionally with a message).")

    @Option(name: .long, help: "Notification body; also posts a macOS notification.")
    var message: String?
    @OptionGroup var target: WorkspaceTargetOption

    init() {
        self.message = nil
        self.target = WorkspaceTargetOption()
    }

    func makeCommand() throws -> ControlCommand {
        ControlCommand(verb: .notify, workspace: try requireSelector(target), message: message)
    }

    func run() throws { _ = try sendControl(makeCommand(), retriable: false) }
}
