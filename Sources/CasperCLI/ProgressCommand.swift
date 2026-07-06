import ArgumentParser
import CasperCore

/// `casper progress set …` / `casper progress clear` — report task progress.
struct ProgressCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "progress",
        abstract: "Report task progress of a workspace.",
        subcommands: [Set.self, Clear.self])

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Set task progress (total, current task, label).")

        @Option(name: .long, help: "Total number of tasks.")
        var total: Int
        @Option(name: .long, help: "1-based index of the current task.")
        var current: Int
        @Option(name: .long, help: "Label of the current task.")
        var label: String
        @OptionGroup var target: WorkspaceTargetOption

        func makeCommand() throws -> ControlCommand {
            guard ProgressSynthesis.todos(total: total, current: current, label: label) != nil else {
                throw exitWithError("invalid progress \(current)/\(total) (need 1 <= current <= total)")
            }
            let selector = try requireSelector(target)
            return ControlCommand(
                verb: .progressSet, workspace: selector,
                total: total, current: current, label: label)
        }

        func run() throws { _ = try sendControl(makeCommand(), retriable: false) }
    }

    struct Clear: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Clear all progress.")

        @OptionGroup var target: WorkspaceTargetOption

        func makeCommand() throws -> ControlCommand {
            ControlCommand(verb: .progressClear, workspace: try requireSelector(target))
        }

        func run() throws { _ = try sendControl(makeCommand(), retriable: false) }
    }
}
