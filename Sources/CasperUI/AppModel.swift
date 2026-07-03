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

    /// Re-probe a folder path for Git backing. Injectable for tests.
    @ObservationIgnored var gitReprobe: (String) -> WorkspaceFactory.GitInfo? = {
        AppModel.gitProbePath($0)
    }

    /// Test hook fired after each successful/attempted persist. nil in production.
    @ObservationIgnored var onPersistForTest: (() -> Void)?

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
        let folderPath = folderURL.path
        if spaces.contains(where: { $0.folderPath == folderPath
            || $0.folderPath == URL(fileURLWithPath: folderPath).standardizedFileURL.path }) {
            CasperLog.app.error("folder already open as a Space: \(folderPath, privacy: .public)")
            return
        }
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

    /// Create a linked workspace (new branch + worktree under
    /// `.casper/worktrees/<branch>`) in a Git Space. Returns false when the Space
    /// is missing, not a Git repo, the name is unusable, or the worktree cannot be
    /// created.
    @discardableResult
    func addLinkedWorkspace(spaceID: UUID, name: String) -> Bool {
        guard let si = spaces.firstIndex(where: { $0.id == spaceID }),
              spaces[si].isGitRepo,
              let branch = GitBranchName.sanitize(name) else { return false }
        let folder = spaces[si].folderPath
        let base = spaces[si].workspaces.first?.branch ?? ""
        let worktreePath = folder + "/.casper/worktrees/" + branch

        let portBase: Int
        do { portBase = try portAllocator.allocate() } catch {
            CasperLog.app.error(
                "cannot add workspace: no free port block: \(String(describing: error), privacy: .public)")
            return false
        }
        // `git_worktree_add` creates only the leaf directory, not the
        // `.casper/worktrees/` parent, so make sure that exists first.
        let worktreesDir = URL(fileURLWithPath: worktreePath).deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: worktreesDir, withIntermediateDirectories: true)
        do {
            _ = try WorktreeManager.create(
                repoPath: folder, name: branch, worktreePath: worktreePath,
                base: base.isEmpty ? nil : base)
        } catch {
            portAllocator.release(portBase)
            CasperLog.app.error(
                "worktree creation failed: \(String(describing: error), privacy: .public)")
            return false
        }
        ensureCasperExcluded(folderPath: folder)
        let ws = WorkspaceFactory.makeLinkedWorkspace(
            name: branch, worktreePath: worktreePath, branch: branch,
            baseBranch: base, portBase: portBase)
        spaces[si].workspaces.append(ws)
        selectedWorkspaceID = ws.id
        persist()
        return true
    }

    /// Drop a linked workspace (never a primary); releases its port, leaves the
    /// worktree and branch on disk.
    func removeWorkspace(id: UUID) {
        guard let at = locate(id) else { return }
        guard spaces[at.space].workspaces[at.workspace].kind == .linked else { return }
        let ws = spaces[at.space].workspaces.remove(at: at.workspace)
        portAllocator.release(ws.portBase)
        lastSeen[ws.id] = nil
        if selectedWorkspaceID == id {
            selectedWorkspaceID = spaces.first?.workspaces.first?.id
        }
        persist()
    }

    /// Best-effort: ensure `.casper/` is in the repo's `.git/info/exclude` so
    /// managed worktrees never show as untracked. Uses the pure `GitInfoExclude`
    /// computation; a write failure logs and is ignored.
    func ensureCasperExcluded(folderPath: String) {
        let excludePath = folderPath + "/.git/info/exclude"
        let current = try? String(contentsOfFile: excludePath, encoding: .utf8)
        guard let updated = GitInfoExclude.ensuring(
            GitInfoExclude.casperEntry, in: current) else { return }
        do {
            try FileManager.default.createDirectory(
                atPath: folderPath + "/.git/info", withIntermediateDirectories: true)
            try updated.write(toFile: excludePath, atomically: true, encoding: .utf8)
        } catch {
            CasperLog.app.error(
                "could not update .git/info/exclude: \(String(describing: error), privacy: .public)")
        }
    }

    func persist() {
        do {
            try sessionStore.save(Session(spaces: spaces))
        } catch {
            CasperLog.app.error("failed to persist session: \(String(describing: error), privacy: .public)")
        }
        onPersistForTest?()
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
        var promoted = false
        for si in spaces.indices where !spaces[si].isGitRepo {
            guard let info = gitReprobe(spaces[si].folderPath) else { continue }
            spaces[si].isGitRepo = true
            spaces[si].workspaces[0].branch = info.branch
            ensureCasperExcluded(folderPath: spaces[si].folderPath)
            promoted = true
        }
        if promoted { persist() }
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
    /// Uses `Repository.open`, an exact-path open, rather than `discover`,
    /// which walks up to parent directories — a Space must root at the
    /// folder the user picked, not at an ancestor repository.
    static func gitProbe(_ url: URL) -> WorkspaceFactory.GitInfo? {
        guard let repo = try? Repository.open(atPath: url.path),
              let workdir = repo.workdirPath else { return nil }
        let branch = (try? repo.headBranchName()) ?? ""
        let remote = (try? repo.remoteURL(named: "origin")) ?? nil
        return WorkspaceFactory.GitInfo(
            canonicalPath: URL(fileURLWithPath: workdir).standardizedFileURL.path,
            branch: branch, remoteURL: remote)
    }

    /// Path variant of `gitProbe` for re-probing an already-open Space.
    static func gitProbePath(_ path: String) -> WorkspaceFactory.GitInfo? {
        gitProbe(URL(fileURLWithPath: path))
    }
}
