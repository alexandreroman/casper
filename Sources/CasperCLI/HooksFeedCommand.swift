import ArgumentParser
import CasperAgents
import Foundation

/// `casper hooks feed` — invoked by Claude Code hooks (the generated
/// `settings.local.json` calls this). Reads the hook JSON on stdin, wraps it
/// with the surface's workspace id, and relays it to the app over the
/// `CASPER_SOCKET` Unix-domain socket. Never blocks the agent: missing env,
/// a missing socket, or a transport failure all exit 0.
public struct HooksFeedCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "feed",
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
        // Throwing read: an I/O failure must never crash the agent, so treat any
        // failure as empty input (the guard below then exits 0).
        let stdin = (try? FileHandle.standardInput.readToEnd()) ?? Data()
        guard let message = Self.makeMessage(stdin: stdin, environment: environment),
              let socketPath = environment["CASPER_SOCKET"]
        else { return }
        // Best-effort: a hook must never block or fail the agent.
        try? HookSocketClient.send(message, toSocketAt: socketPath)
    }
}
