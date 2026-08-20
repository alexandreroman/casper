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
        // Treat an empty or whitespace-only selector as absent so `requireSelector`
        // raises its clear "no target workspace" error instead of round-tripping a
        // useless empty selector to the app.
        (workspace ?? environment["CASPER_WORKSPACE_ID"]).flatMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
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

/// Reject a URL that is not absolute (scheme + host) with a clear message. Shared
/// by every verb that takes a URL, so they all refuse the same inputs with the
/// same wording.
func requireAbsoluteURL(_ url: String) throws {
    guard let parsed = URL(string: url), parsed.scheme != nil, parsed.host != nil else {
        throw exitWithError("invalid url '\(url)' (expected an absolute URL like https://example.com)")
    }
}

/// Resolve a filesystem path against the CLI process's working directory.
///
/// Paths travel over the control socket as plain strings and are used by the GUI
/// app, whose own working directory is `/` when it was launched from Finder — so
/// a relative path must be absolutized here, on the side that still knows the
/// user's shell directory. Resolving it CLI-side also makes the echoed JSON
/// report the path the file actually landed at.
func absolutePath(_ path: String) -> String {
    let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    return URL(fileURLWithPath: path, relativeTo: workingDirectory).standardizedFileURL.path
}

/// A workspace-scoped subcommand whose entire job is "send one control command,
/// then print the workspace it landed in". Conformers supply only the command;
/// the default `run()` below is the send-and-emit body they would otherwise all
/// repeat verbatim.
///
/// None of these verbs is idempotent, hence the uniform `retriable: false`: a
/// transport-level resend could apply the same mutation twice.
protocol WorkspaceRefCommand: ParsableCommand {
    func makeCommand() throws -> ControlCommand

    /// How long to wait for the app's reply. Defaults to `sendControl`'s own 5 s;
    /// override it for a verb the app answers more slowly.
    var commandTimeout: TimeInterval { get }
}

extension WorkspaceRefCommand {
    var commandTimeout: TimeInterval { 5 }

    func run() throws {
        let response = try sendControl(makeCommand(), retriable: false, timeout: commandTimeout)
        emit(WorkspaceRefOut(workspace: response.workspaceRef))
    }
}

extension ControlResponse {
    /// The workspace the command landed in, as the CLI prints it. A reply without
    /// one renders as an empty string rather than a missing key, so every success
    /// shape keeps the same set of keys.
    var workspaceRef: String { workspace ?? "" }
}

/// Send a control command to the running app over `$CASPER_CONTROL_SOCKET`.
/// Converts a transport failure or an `ok: false` reply into a thrown `ExitCode`
/// (identical contract to the debug channel's `CasperCLI.run`).
@discardableResult
func sendControl(_ command: ControlCommand, retriable: Bool, timeout: TimeInterval = 5) throws -> ControlResponse {
    guard let socketPath = ProcessInfo.processInfo.environment["CASPER_CONTROL_SOCKET"] else {
        throw exitWithError("Casper is not running (CASPER_CONTROL_SOCKET unset); run inside a Casper terminal")
    }
    let response: ControlResponse
    do {
        response = try ControlSocketClient.send(
            command, toSocketAt: socketPath, timeout: timeout, retriable: retriable)
    } catch let error as ControlSocketError {
        throw exitWithError(error.reason)
    }
    guard response.ok else { throw exitWithError(response.error ?? "unknown") }
    return response
}
