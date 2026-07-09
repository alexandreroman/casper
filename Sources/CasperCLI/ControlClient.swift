import ArgumentParser
import CasperCore
import Foundation

/// The global `--workspace` target selector, shared by every workspace-scoped
/// command. Defaults to `$CASPER_WORKSPACE_ID` (set in every Casper terminal).
struct WorkspaceTargetOption: ParsableArguments {
    @Option(name: .long, help: "Target workspace id or name (defaults to $CASPER_WORKSPACE_ID).")
    var workspace: String?

    func resolvedSelector(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        workspace ?? environment["CASPER_WORKSPACE_ID"]
    }
}

/// Normalize a `--command` option so an empty string means "no command",
/// keeping `terminal new` and `workspace new` consistent.
func normalizedCommand(_ command: String?) -> String? {
    command.flatMap { $0.isEmpty ? nil : $0 }
}

/// Resolve a required target selector or exit with a clear message.
func requireSelector(_ option: WorkspaceTargetOption) throws -> String {
    guard let selector = option.resolvedSelector() else {
        throw exitWithError("no target workspace: run inside a Casper terminal or pass --workspace")
    }
    return selector
}

/// Send a control command to the running app over `$CASPER_CONTROL_SOCKET`.
/// Converts a transport failure or an `ok: false` reply into a thrown `ExitCode`
/// (identical contract to the debug channel's `CasperCLI.run`).
@discardableResult
func sendControl(_ command: ControlCommand, retriable: Bool) throws -> ControlResponse {
    guard let socketPath = ProcessInfo.processInfo.environment["CASPER_CONTROL_SOCKET"] else {
        throw exitWithError("Casper is not running (CASPER_CONTROL_SOCKET unset); run inside a Casper terminal")
    }
    let response: ControlResponse
    do {
        response = try ControlSocketClient.send(command, toSocketAt: socketPath, retriable: retriable)
    } catch let error as ControlSocketError {
        throw exitWithError(error.reason)
    }
    guard response.ok else { throw exitWithError(response.error ?? "unknown") }
    return response
}
