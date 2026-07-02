import AppKit
import CasperAgents
import CasperCore
import Foundation
import Observation
import UserNotifications

/// The single owner of runtime UI state and the bridge from the non-observable
/// core types to SwiftUI. Membership changes (add/remove folder) persist
/// synchronously; high-frequency agent-state changes (Task 4) debounce.
@MainActor
@Observable
final class AppModel {
    private(set) var workspaces: [Workspace]
    var selectedWorkspaceID: UUID?

    @ObservationIgnored private let sessionStore: SessionStore
    @ObservationIgnored private var portAllocator: PortAllocator

    /// Timestamp of the last hook message per workspace, for heartbeat staleness.
    @ObservationIgnored private var lastSeen: [UUID: Date] = [:]
    @ObservationIgnored private var saveWorkItem: DispatchWorkItem?

    /// Seconds of silence before a workspace with prior activity goes `unknown`.
    @ObservationIgnored var heartbeatTimeout: TimeInterval = 30

    /// Whether the app's window currently has key focus. Injectable for tests.
    @ObservationIgnored var isWindowKey: () -> Bool = { NSApp.keyWindow != nil }

    /// Delivers a local notification. Injectable for tests; the default posts a
    /// best-effort `UserNotifications` request (a bare executable without a
    /// bundle id may silently no-op, which is acceptable in dev builds).
    @ObservationIgnored var deliverNotification: (String, String) -> Void = { title, body in
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    init(
        sessionStore: SessionStore,
        portAllocator: PortAllocator = PortAllocator(),
        session: Session = Session()
    ) {
        self.sessionStore = sessionStore
        self.portAllocator = portAllocator
        self.workspaces = session.workspaces
        self.selectedWorkspaceID = session.workspaces.first?.id
        // Reserve restored port blocks so a later allocate() never collides.
        for ws in session.workspaces { self.portAllocator.reserve(ws.portBase) }
    }

    var isEmpty: Bool { workspaces.isEmpty }

    func addWorkspace(folderURL: URL, probe: (URL) -> WorkspaceFactory.RepoInfo?) {
        let portBase: Int
        do {
            portBase = try portAllocator.allocate()
        } catch {
            CasperLog.app.error("cannot add workspace: no free port block: \(String(describing: error), privacy: .public)")
            return
        }
        let ws = WorkspaceFactory.makeWorkspace(
            folderURL: folderURL, probe: probe, portBase: portBase)
        workspaces.append(ws)
        selectedWorkspaceID = ws.id
        persist()
    }

    func removeWorkspace(id: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        portAllocator.release(workspaces[index].portBase)
        workspaces.remove(at: index)
        if selectedWorkspaceID == id { selectedWorkspaceID = workspaces.first?.id }
        persist()
    }

    func persist() {
        do {
            try sessionStore.save(Session(workspaces: workspaces))
        } catch {
            CasperLog.app.error("failed to persist session: \(String(describing: error), privacy: .public)")
        }
    }

    func handleHookMessage(_ message: HookMessage, now: Date) {
        guard let index = workspaces.firstIndex(where: { $0.id == message.workspaceId })
        else { return }
        guard let event = try? HookEventParser.parse(message.hookPayload) else { return }

        lastSeen[message.workspaceId] = now
        let focused = (message.workspaceId == selectedWorkspaceID) && isWindowKey()
        let effect = AgentStateReducer.apply(event, to: &workspaces[index], focused: focused)
        if case .notify(let title, let body)? = effect {
            deliverNotification(title, body)
        }
        scheduleSave()
    }

    func tickHeartbeat(now: Date) {
        let stale = HeartbeatMonitor.staleWorkspaces(
            lastSeen: lastSeen, now: now, timeout: heartbeatTimeout)
        for id in stale {
            guard let index = workspaces.firstIndex(where: { $0.id == id }) else { continue }
            workspaces[index].agentState = .unknown
        }
        if !stale.isEmpty { scheduleSave() }
    }

    /// Debounced persistence for high-frequency agent-state changes.
    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.persist() }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    func flushPendingSave() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        persist()
    }
}
