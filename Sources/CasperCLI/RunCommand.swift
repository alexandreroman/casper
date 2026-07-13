import ArgumentParser
import CasperCore

/// `casper run [name]` — run a named command from the workspace's `.casper.json`
/// in a new visible terminal. Defaults to the command named `run`.
struct RunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a named command from the workspace's .casper.json (defaults to 'run').")

    @Argument(help: "Named command to run (defaults to 'run').") var name: String = "run"
    @OptionGroup var target: WorkspaceTargetOption

    func makeCommand() throws -> ControlCommand {
        ControlCommand(verb: .run, workspace: try requireSelector(target), name: name)
    }

    func run() throws {
        let response = try sendControl(makeCommand(), retriable: false)
        guard let info = response.terminals?.first else { throw exitWithError("no terminal returned") }
        emit(RunOut(command: name, terminal: info.id, workspace: response.workspace ?? ""))
    }
}
