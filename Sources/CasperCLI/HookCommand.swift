import ArgumentParser
import CasperAgents
import Foundation

/// `casper hook` — invoked by Claude Code hooks. Reads the hook JSON on stdin,
/// wraps it with the surface's workspace id, and relays it to the app over the
/// `CASPER_SOCKET` Unix-domain socket. Never blocks the agent: missing env,
/// a missing socket, or a transport failure all exit 0.
public struct HookCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "hook",
        abstract: "Relay a Claude Code hook event to the Casper app.")

    public init() {}

    /// Build the wire envelope from raw stdin and the process environment, or
    /// `nil` when `CASPER_WORKSPACE_ID` is absent or not a UUID.
    public static func makeMessage(
        stdin: Data, environment: [String: String]
    ) -> HookMessage? {
        guard let raw = environment["CASPER_WORKSPACE_ID"],
              let workspaceId = UUID(uuidString: raw)
        else { return nil }
        return HookMessage(workspaceId: workspaceId, hookPayload: stdin)
    }

    public func run() throws {
        let environment = ProcessInfo.processInfo.environment
        let stdin = FileHandle.standardInput.readDataToEndOfFile()
        guard let message = Self.makeMessage(stdin: stdin, environment: environment),
              let socketPath = environment["CASPER_SOCKET"]
        else { return }
        // Best-effort: a hook must never block or fail the agent.
        try? HookSocketClient.send(message, toSocketAt: socketPath)
    }
}
