import Foundation

/// Pure helper deciding which workspaces have gone silent. The app's periodic
/// timer (Plan 5) feeds the result to `AgentStateStore.markUnknown`. Kept pure
/// (clock injected as `now`) so it is testable without real time.
public enum HeartbeatMonitor {
    /// Workspace ids whose most recent activity is strictly older than
    /// `now - timeout`. A workspace exactly at the boundary is not yet stale.
    public static func staleWorkspaces(
        lastSeen: [UUID: Date], now: Date, timeout: TimeInterval
    ) -> [UUID] {
        lastSeen
            .filter { now.timeIntervalSince($0.value) > timeout }
            .map(\.key)
    }
}
