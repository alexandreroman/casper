import Foundation

/// The wire envelope `casper hooks feed` sends to the app: a workspace id plus the raw
/// Claude Code hook JSON, so the receiver can decode it with `HookEventParser`.
public struct HookMessage: Codable, Equatable, Sendable {
    public let workspaceId: UUID
    public let hookPayload: Data

    public init(workspaceId: UUID, hookPayload: Data) {
        self.workspaceId = workspaceId
        self.hookPayload = hookPayload
    }
}
