import ArgumentParser
import CasperCore

/// `casper progress set …` / `casper progress get` / `casper progress clear` —
/// report and read back task progress.
struct ProgressCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "progress",
        abstract: "Report task progress of a workspace.",
        subcommands: [Set.self, Get.self, Clear.self])

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
            guard total <= ProgressSynthesis.maxSynthesizedTotal else {
                throw exitWithError(
                    "invalid progress: --total \(total) exceeds the maximum of "
                        + "\(ProgressSynthesis.maxSynthesizedTotal)")
            }
            guard ProgressSynthesis.todos(total: total, current: current, label: label) != nil else {
                throw exitWithError("invalid progress \(current)/\(total) (need 1 <= current <= total)")
            }
            let selector = try requireSelector(target)
            return ControlCommand(
                verb: .progressSet, workspace: selector,
                total: total, current: current, label: label)
        }

        func run() throws {
            let response = try sendControl(makeCommand(), retriable: false)
            emit(ProgressOut(
                progress: ProgressBody(total: total, current: current, label: label),
                workspace: response.workspaceRef))
        }
    }

    /// The one read on this surface: whether a bar is up, and at which step.
    /// Exists for the agent plugin's `Stop` hook, which has to tell a turn that
    /// ends with work still in flight from one that ends with the work over, and
    /// cannot see a bar the agent set by hand rather than through a todo tool.
    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Read the progress bar a workspace is showing.")

        @OptionGroup var target: WorkspaceTargetOption

        func makeCommand() throws -> ControlCommand {
            ControlCommand(verb: .progressGet, workspace: try requireSelector(target))
        }

        func run() throws {
            let response = try sendControl(makeCommand(), retriable: true)
            emit(ProgressGetOut(
                progress: response.progress.map {
                    ProgressBody(total: $0.total, current: $0.current, label: $0.label)
                },
                workspace: response.workspaceRef))
        }
    }

    struct Clear: WorkspaceRefCommand {
        static let configuration = CommandConfiguration(abstract: "Clear all progress.")

        @OptionGroup var target: WorkspaceTargetOption

        func makeCommand() throws -> ControlCommand {
            ControlCommand(verb: .progressClear, workspace: try requireSelector(target))
        }
    }
}
