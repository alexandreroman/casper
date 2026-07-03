import AppKit
import CasperAgents
import CasperCore
import CasperGhostty
import CasperGit
import Foundation
import Observation
import UserNotifications

/// The single owner of runtime UI state and the bridge from the non-observable
/// core types to SwiftUI. Membership changes (add/remove folder) persist
/// synchronously; high-frequency agent-state changes (Task 4) debounce.
@MainActor
@Observable
final class AppModel {
    private(set) var spaces: [Space]
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

    /// Set during Task 7 bootstrap once the Ghostty runtime and IPC socket exist.
    @ObservationIgnored var runtime: GhosttyRuntime?
    @ObservationIgnored var casperDirectory: String?
    @ObservationIgnored var socketPath: String?

    /// The one instance shared by the SwiftUI scene (`CasperApp`) and the
    /// AppKit lifecycle (`AppDelegate`). Loads the persisted session from its
    /// default location, falling back to a fresh, temp-backed store if the
    /// default location itself cannot be determined.
    @MainActor static let shared = makeShared()

    @MainActor
    static func makeShared() -> AppModel {
        do {
            let url = try SessionStore.defaultURL()
            let store = SessionStore(fileURL: url)
            let session = try store.load()
            return AppModel(sessionStore: store, session: session)
        } catch {
            CasperLog.app.error(
                "failed to load session, starting fresh: \(String(describing: error), privacy: .public)")
            let fallback = SessionStore(
                fileURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("casper-session.json"))
            return AppModel(sessionStore: fallback)
        }
    }

    init(
        sessionStore: SessionStore,
        portAllocator: PortAllocator = PortAllocator(),
        session: Session = Session()
    ) {
        self.sessionStore = sessionStore
        self.portAllocator = portAllocator
        self.spaces = session.spaces
        self.selectedWorkspaceID = session.spaces.first?.workspaces.first?.id
        // Reserve restored port blocks so a later allocate() never collides.
        for space in session.spaces {
            for ws in space.workspaces { self.portAllocator.reserve(ws.portBase) }
        }
    }

    var isEmpty: Bool { spaces.allSatisfy { $0.workspaces.isEmpty } }

    /// All workspaces across every Space, in sidebar order.
    var allWorkspaces: [Workspace] { spaces.flatMap(\.workspaces) }

    /// Look up a workspace by id across all Spaces.
    func workspace(id: UUID) -> Workspace? {
        for space in spaces {
            if let ws = space.workspaces.first(where: { $0.id == id }) { return ws }
        }
        return nil
    }

    /// Resolve the (space, workspace) index pair for in-place mutation.
    private func locate(_ id: UUID) -> (space: Int, workspace: Int)? {
        for (si, space) in spaces.enumerated() {
            if let wi = space.workspaces.firstIndex(where: { $0.id == id }) {
                return (si, wi)
            }
        }
        return nil
    }

    func addSpace(folderURL: URL, probe: (URL) -> WorkspaceFactory.GitInfo?) {
        let portBase: Int
        do {
            portBase = try portAllocator.allocate()
        } catch {
            CasperLog.app.error(
                "cannot add space: no free port block: \(String(describing: error), privacy: .public)")
            return
        }
        let space = WorkspaceFactory.makeSpace(
            folderURL: folderURL, probe: probe, portBase: portBase)
        spaces.append(space)
        selectedWorkspaceID = space.workspaces.first?.id
        persist()
    }

    func removeSpace(id: UUID) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        let removed = spaces.remove(at: index)
        for ws in removed.workspaces {
            portAllocator.release(ws.portBase)
            lastSeen[ws.id] = nil
        }
        if let sel = selectedWorkspaceID, removed.workspaces.contains(where: { $0.id == sel }) {
            selectedWorkspaceID = spaces.first?.workspaces.first?.id
        }
        persist()
    }

    func persist() {
        do {
            try sessionStore.save(Session(spaces: spaces))
        } catch {
            CasperLog.app.error("failed to persist session: \(String(describing: error), privacy: .public)")
        }
    }

    func handleHookMessage(_ message: HookMessage, now: Date) {
        guard let at = locate(message.workspaceId) else { return }
        guard let event = try? HookEventParser.parse(message.hookPayload) else { return }

        lastSeen[message.workspaceId] = now
        let focused = (message.workspaceId == selectedWorkspaceID) && isWindowKey()
        let effect = AgentStateReducer.apply(
            event, to: &spaces[at.space].workspaces[at.workspace], focused: focused)
        if case .notify(let title, let body)? = effect {
            deliverNotification(title, body)
        }
        scheduleSave()
    }

    func tickHeartbeat(now: Date) {
        let stale = HeartbeatMonitor.staleWorkspaces(
            lastSeen: lastSeen, now: now, timeout: heartbeatTimeout)
        var changed = false
        for id in stale {
            lastSeen[id] = nil  // consumed; don't reprocess this silence every tick
            guard let at = locate(id) else { continue }
            if spaces[at.space].workspaces[at.workspace].agentState != .unknown {
                spaces[at.space].workspaces[at.workspace].agentState = .unknown
                changed = true
            }
        }
        if changed { scheduleSave() }
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

    /// The per-surface environment injected into a terminal so `casper hooks
    /// feed` resolves and the agent sees its reserved ports.
    func surfaceConfiguration(
        for workspace: Workspace, terminal: Surface
    ) -> GhosttySurfaceConfiguration {
        guard case .terminal(let cwd, let command) = terminal.kind else {
            return GhosttySurfaceConfiguration()
        }
        var config = GhosttySurfaceConfiguration(workingDirectory: cwd, command: command)
        if let socketPath {
            config.environment = ClaudeCodeAdapter.surfaceEnvironment(
                socketPath: socketPath,
                workspaceId: workspace.id,
                portBase: workspace.portBase,
                casperDirectory: casperDirectory,
                basePath: ProcessInfo.processInfo.environment["PATH"]
            )
        }
        return config
    }

    /// Open a directory picker and adopt the chosen folder as a workspace.
    func presentAddFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addSpace(folderURL: url, probe: Self.gitProbe)
    }

    /// Probe a folder for Git backing using CasperGit. Static so it holds no
    /// state; returns nil for a non-Git folder (accepted per UI-1 design).
    static func gitProbe(_ url: URL) -> WorkspaceFactory.GitInfo? {
        guard let repo = try? Repository.discover(startingAt: url.path),
              let workdir = repo.workdirPath else { return nil }
        let branch = (try? repo.headBranchName()) ?? ""
        return WorkspaceFactory.GitInfo(
            canonicalPath: URL(fileURLWithPath: workdir).standardizedFileURL.path,
            branch: branch)
    }
}
