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

    /// The surface that last became first responder (runtime-only, not persisted).
    var focusedSurfaceID: UUID?

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
    var runtime: GhosttyRuntime?
    @ObservationIgnored var casperDirectory: String?
    @ObservationIgnored var socketPath: String?

    /// Live surface views, keyed by surface id. Holds terminal
    /// (`GhosttySurfaceView`) and browser (`WKWebView`) views. Persisting these
    /// across SwiftUI rebuilds keeps each PTY or web page alive when the layout
    /// tree is restructured.
    @ObservationIgnored private var surfaceViews: [UUID: NSView] = [:]

    /// Live browser coordinators, keyed by surface id. Each owns a browser
    /// surface's `WKWebView` and navigation state; caching them here keeps the
    /// web page and address alive across SwiftUI rebuilds.
    @ObservationIgnored private var browserCoordinators: [UUID: BrowserCoordinator] = [:]

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
            CasperLog.app.failure("failed to load session, starting fresh", error)
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
        if let ws = session.spaces.first?.workspaces.first {
            self.focusedSurfaceID = LayoutTree.surfaceIDs(ws.layout).first
        }
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

    /// The Space that owns `workspace`, if any. A workspace has no back-pointer
    /// to its Space, so this searches the spaces' workspace arrays.
    func space(for workspace: Workspace) -> Space? {
        spaces.first { $0.workspaces.contains { $0.id == workspace.id } }
    }

    /// Resolve the (space, workspace) index pair of the first workspace matching
    /// `predicate`, for in-place mutation.
    private func indexPair(where predicate: (Workspace) -> Bool) -> (space: Int, workspace: Int)? {
        for (si, space) in spaces.enumerated() {
            if let wi = space.workspaces.firstIndex(where: predicate) {
                return (si, wi)
            }
        }
        return nil
    }

    /// Resolve the (space, workspace) index pair for in-place mutation.
    private func locate(_ id: UUID) -> (space: Int, workspace: Int)? {
        indexPair { $0.id == id }
    }

    func addSpace(folderURL: URL, probe: (URL) -> WorkspaceFactory.GitInfo?) {
        let folderPath = folderURL.path
        let candidate = URL(fileURLWithPath: folderPath).resolvingSymlinksInPath().path
        if spaces.contains(where: {
            URL(fileURLWithPath: $0.folderPath).resolvingSymlinksInPath().path == candidate
        }) {
            CasperLog.app.error("folder already open as a Space: \(folderPath, privacy: .public)")
            return
        }
        let portBase: Int
        do {
            portBase = try portAllocator.allocate()
        } catch {
            CasperLog.app.failure("cannot add space: no free port block", error)
            return
        }
        let space = WorkspaceFactory.makeSpace(
            folderURL: folderURL, probe: probe, portBase: portBase)
        spaces.append(space)
        selectWorkspace(space.workspaces.first?.id)
        persist()
    }

    func removeSpace(id: UUID) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        let removed = spaces.remove(at: index)
        for ws in removed.workspaces {
            portAllocator.release(ws.portBase)
            lastSeen[ws.id] = nil
            discardSurfaceViews(LayoutTree.surfaceIDs(ws.layout))
        }
        if let sel = selectedWorkspaceID, removed.workspaces.contains(where: { $0.id == sel }) {
            selectWorkspace(spaces.first?.workspaces.first?.id)
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
            CasperLog.app.failure("cannot add workspace: no free port block", error)
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
            CasperLog.app.failure("worktree creation failed", error)
            return false
        }
        ensureCasperExcluded(folderPath: folder)
        let ws = WorkspaceFactory.makeLinkedWorkspace(
            name: branch, worktreePath: worktreePath, branch: branch,
            baseBranch: base, portBase: portBase)
        spaces[si].workspaces.append(ws)
        selectWorkspace(ws.id)
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
        discardSurfaceViews(LayoutTree.surfaceIDs(ws.layout))
        if selectedWorkspaceID == id {
            selectWorkspace(spaces.first?.workspaces.first?.id)
        }
        persist()
    }

    /// Select a workspace and move focus to its top-left terminal. The sidebar's
    /// `List(selection:)` and every programmatic selection route through here so a
    /// switch always relocates keyboard focus, instead of leaving it on the
    /// previous workspace's surface (or letting AppKit hand it to the inspector's
    /// URL field). `surfaceIDs(...).first` is the depth-first, top-left surface.
    /// `focusActiveSurfaceView()` covers the already-attached case; a freshly
    /// mounted terminal's `onAttach` covers the not-yet-attached case. When `id` is
    /// nil or resolves to no workspace, only the selection changes.
    func selectWorkspace(_ id: UUID?) {
        selectedWorkspaceID = id
        guard let id, let ws = workspace(id: id) else { return }
        focusedSurfaceID = LayoutTree.surfaceIDs(ws.layout).first
        focusActiveSurfaceView()
    }

    func focusSurface(_ id: UUID) { focusedSurfaceID = id }

    /// Move AppKit keyboard focus to the focused surface's cached view. Deferred
    /// to the next runloop turn so the view is attached to the window first: a
    /// tab switch (or a new/closed surface) re-parents the newly active surface's
    /// view during the SwiftUI update that runs right after this state change.
    /// A no-op for surfaces with no cached `NSView` (e.g. the diff surface),
    /// which manage their own focus.
    private func focusActiveSurfaceView() {
        guard let id = focusedSurfaceID else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let view = self.surfaceViews[id], let window = view.window
                else { return }
                window.makeFirstResponder(view)
            }
        }
    }

    /// Claim AppKit first responder for a surface only when the model already
    /// treats it as focused. Called from a terminal view's `onAttach` once it is
    /// live in a window: at cold launch (and after a workspace switch) nothing else
    /// pushes first responder to the terminal, so AppKit's key-view loop would
    /// otherwise hand it to the inspector's URL field. The `focusedSurfaceID` guard
    /// keeps a freshly mounted background surface from stealing focus.
    private func focusSurfaceViewIfActive(_ id: UUID) {
        guard id == focusedSurfaceID else { return }
        focusActiveSurfaceView()
    }

    /// The (space, workspace) index pair whose layout contains `surfaceID`.
    private func locateSurface(_ surfaceID: UUID) -> (space: Int, workspace: Int)? {
        indexPair { LayoutTree.surfaceIDs($0.layout).contains(surfaceID) }
    }

    private func newTerminalSurface(cwd: String) -> Surface {
        Surface.terminal(cwd: cwd)
    }

    /// Shared tail of every split-based surface addition: split the leaf holding
    /// `focused` in workspace `at` to insert `surface` along `orientation`/`side`,
    /// move focus to the new surface, persist, and re-anchor AppKit first
    /// responder. Callers resolve their own target and surface, then delegate here.
    private func insertSurfaceBySplitting(
        at: (space: Int, workspace: Int), focused: UUID,
        orientation: LayoutNode.Orientation, side: LayoutTree.InsertSide, surface: Surface
    ) {
        let (layout, newFocus) = LayoutTree.split(
            spaces[at.space].workspaces[at.workspace].layout,
            focused: focused, orientation: orientation, side: side, surface: surface)
        spaces[at.space].workspaces[at.workspace].layout = layout
        focusedSurfaceID = newFocus
        persist()
        focusActiveSurfaceView()
    }

    /// Add a new terminal by splitting the anchored surface (or the focused one
    /// when `anchor` is nil) to the RIGHT.
    func applyNewTerminal(anchor: UUID? = nil) {
        guard let target = anchor ?? focusedSurfaceID, let at = locateSurface(target) else { return }
        let cwd = spaces[at.space].workspaces[at.workspace].worktreePath
        insertSurfaceBySplitting(
            at: at, focused: target, orientation: .horizontal, side: .after,
            surface: newTerminalSurface(cwd: cwd))
    }

    /// Split the given surface with a new terminal in `direction` (the pane
    /// context-menu action; always creates a terminal).
    func applySplit(from surfaceID: UUID, direction: GhosttySplitDirectionLike) {
        guard let at = locateSurface(surfaceID) else { return }
        let cwd = spaces[at.space].workspaces[at.workspace].worktreePath
        let (orientation, side) = LayoutTree.orientationAndSide(for: direction)
        insertSurfaceBySplitting(
            at: at, focused: surfaceID, orientation: orientation, side: side,
            surface: newTerminalSurface(cwd: cwd))
    }

    func applyNewSplit(_ direction: GhosttySplitDirectionLike) {
        guard let focus = focusedSurfaceID, let at = locateSurface(focus) else { return }
        let cwd = spaces[at.space].workspaces[at.workspace].worktreePath
        let (orientation, side) = LayoutTree.orientationAndSide(for: direction)
        insertSurfaceBySplitting(
            at: at, focused: focus, orientation: orientation, side: side,
            surface: newTerminalSurface(cwd: cwd))
    }

    func applyCloseFocusedSurface() {
        guard let focus = focusedSurfaceID else { return }
        applyCloseSurface(focus)
    }

    /// Close the given surface (from a tab-bar close button or the keyboard).
    /// Preserves the active tab when a background tab is closed; closing the
    /// last surface closes the workspace non-destructively.
    func applyCloseSurface(_ surfaceID: UUID) {
        guard let at = locateSurface(surfaceID) else { return }
        let wasFocused = focusedSurfaceID == surfaceID
        let (layout, newFocus) = LayoutTree.closeSurface(
            spaces[at.space].workspaces[at.workspace].layout, surface: surfaceID)
        if let layout {
            spaces[at.space].workspaces[at.workspace].layout = layout
            if wasFocused { focusedSurfaceID = newFocus }
            discardSurfaceViews([surfaceID])
            persist()
            focusActiveSurfaceView()
            return
        }
        // Last surface closed -> close the workspace (non-destructive).
        let ws = spaces[at.space].workspaces[at.workspace]
        discardSurfaceViews(LayoutTree.surfaceIDs(ws.layout))
        if wasFocused { focusedSurfaceID = nil }
        if ws.kind == .linked {
            removeWorkspace(id: ws.id)
        } else {
            removeSpace(id: spaces[at.space].id)
        }
    }

    /// The persistent view for a terminal surface, created on first use. Returns nil
    /// for a non-terminal surface or before the runtime exists.
    func surfaceView(for surface: Surface, in workspace: Workspace) -> GhosttySurfaceView? {
        guard let runtime, case .terminal = surface.kind else { return nil }
        if let existing = surfaceViews[surface.id] as? GhosttySurfaceView {
            return existing
        }
        let view = GhosttySurfaceView(
            runtime: runtime,
            configuration: surfaceConfiguration(for: workspace, terminal: surface),
            surfaceID: surface.id,
            onFocus: { [weak self] id in self?.focusSurface(id) },
            onAttach: { [weak self] id in self?.focusSurfaceViewIfActive(id) },
            onClose: { [weak self] id in self?.applyCloseSurface(id) })
        surfaceViews[surface.id] = view
        return view
    }

    /// The persistent coordinator (and its `WKWebView`) for a browser surface,
    /// created on first use and loaded with the surface's URL. Cached by
    /// `Surface.id` so navigation state and the web view survive layout churn.
    func browserCoordinator(for surface: Surface) -> BrowserCoordinator? {
        guard case .browser(let url) = surface.kind else { return nil }
        if let existing = browserCoordinators[surface.id] { return existing }
        let coordinator = BrowserCoordinator(surfaceID: surface.id, url: url)
        coordinator.onCommitURL = { [weak self] url in self?.setBrowserURL(surface.id, url) }
        coordinator.onFocus = { [weak self] in self?.focusSurface(surface.id) }
        browserCoordinators[surface.id] = coordinator
        return coordinator
    }

    /// Add a new browser by splitting the anchored surface (or the focused one
    /// when `anchor` is nil) to the RIGHT.
    func applyNewBrowser(anchor: UUID? = nil) {
        guard let target = anchor ?? focusedSurfaceID, let at = locateSurface(target) else { return }
        let surface = Surface.blankBrowser()
        insertSurfaceBySplitting(
            at: at, focused: target, orientation: .horizontal, side: .after, surface: surface)
    }

    /// Whether the workspace's owning Space is a Git repository.
    func isWorkspaceGitBacked(_ workspace: Workspace) -> Bool {
        space(for: workspace)?.isGitRepo ?? false
    }

    /// Compute the working-tree-vs-HEAD diff of a workspace's worktree. Returns nil
    /// when the workspace is not Git-backed or the diff fails.
    func computeDiff(for workspace: Workspace) -> GitDiff? {
        do {
            let repo = try Repository.open(atPath: workspace.worktreePath)
            return try repo.diffWorkdirToHead()
        } catch {
            CasperLog.app.failure("diff failed", error)
            return nil
        }
    }

    /// The workspace's working-tree-vs-HEAD line counts, or nil when not
    /// Git-backed or the diff fails. Feeds the detail toolbar's `+INS −DEL`.
    func diffSummary(for workspace: Workspace) -> (insertions: Int, deletions: Int)? {
        computeDiff(for: workspace).map { ($0.insertions, $0.deletions) }
    }

    /// Rewrite a browser surface's persisted URL (address-bar navigation).
    /// Searches the layout trees first; when the surface isn't in any layout, it
    /// falls back to each workspace's inspector browser, which lives outside the
    /// tree.
    func setBrowserURL(_ surfaceID: UUID, _ url: URL) {
        if let at = locateSurface(surfaceID) {
            let updated = LayoutTree.mapSurface(
                spaces[at.space].workspaces[at.workspace].layout, id: surfaceID) { s in
                    if case .browser = s.kind { return Surface(id: s.id, kind: .browser(url: url)) }
                    return s
                }
            spaces[at.space].workspaces[at.workspace].layout = updated
            persist()
            return
        }
        if let at = indexPair(where: { $0.inspector.browser.id == surfaceID }) {
            spaces[at.space].workspaces[at.workspace].inspector.browser =
                Surface(id: surfaceID, kind: .browser(url: url))
            persist()
        }
    }

    /// Flip the inspector panel's collapsed state for a workspace (toolbar toggle).
    func toggleInspectorCollapsed(for workspaceID: UUID) {
        guard let at = locate(workspaceID) else { return }
        spaces[at.space].workspaces[at.workspace].inspector.collapsed.toggle()
        persist()
    }

    /// Select the inspector's active tab, expanding the panel if it was collapsed.
    func setInspectorTab(_ tab: InspectorTab, for workspaceID: UUID) {
        guard let at = locate(workspaceID) else { return }
        spaces[at.space].workspaces[at.workspace].inspector.tab = tab
        spaces[at.space].workspaces[at.workspace].inspector.collapsed = false
        persist()
    }

    /// Explicitly set the inspector's collapsed state (the panel's collapse button).
    func setInspectorCollapsed(_ collapsed: Bool, for workspaceID: UUID) {
        guard let at = locate(workspaceID) else { return }
        spaces[at.space].workspaces[at.workspace].inspector.collapsed = collapsed
        persist()
    }

    /// Persist the inspector panel's width for a workspace. Called from the panel's
    /// live width measurement as the user drags the divider; clamps to the allowed
    /// range and no-ops when the (rounded) width is unchanged so a drag does not
    /// thrash the store. Uses the debounced `scheduleSave()` since it fires rapidly
    /// during a resize.
    func setInspectorWidth(_ width: CGFloat, for workspaceID: UUID) {
        guard let at = locate(workspaceID) else { return }
        let clamped = min(max(Double(width), InspectorState.minWidth), InspectorState.maxWidth)
        // Round to whole points: sub-point layout jitter must not trigger saves.
        guard clamped.rounded() != spaces[at.space].workspaces[at.workspace].inspector.width.rounded()
        else { return }
        spaces[at.space].workspaces[at.workspace].inspector.width = clamped
        scheduleSave()
    }

    /// Drop cached views and browser coordinators for the given surface ids
    /// (their PTYs or `WKWebView`s are freed on deinit).
    private func discardSurfaceViews(_ ids: [UUID]) {
        for id in ids {
            surfaceViews[id] = nil
            browserCoordinators[id] = nil
        }
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
            CasperLog.app.failure("could not update .git/info/exclude", error)
        }
    }

    func persist() {
        do {
            try sessionStore.save(Session(spaces: spaces))
        } catch {
            CasperLog.app.failure("failed to persist session", error)
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
            guard let info = gitReprobe(spaces[si].folderPath),
                  !spaces[si].workspaces.isEmpty else { continue }
            spaces[si].isGitRepo = true
            spaces[si].workspaces[0].branch = info.branch
            ensureCasperExcluded(folderPath: spaces[si].folderPath)
            promoted = true
        }
        if promoted {
            persist()
        } else if changed {
            scheduleSave()
        }
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

    /// Prompt for a linked-workspace name and create it. AppKit alert with a text
    /// field; no-op on cancel or empty input.
    func presentAddLinkedWorkspacePanel(spaceID: UUID) {
        let alert = NSAlert()
        alert.messageText = "New workspace"
        alert.informativeText = "Name for the new branch and worktree:"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if !addLinkedWorkspace(spaceID: spaceID, name: name) {
            let alert = NSAlert()
            alert.messageText = "Could not create workspace"
            alert.informativeText =
                "\u{201c}\(name)\u{201d} could not be created. A branch or worktree with that name "
                + "may already exist, or the name is not a valid branch name."
            alert.runModal()
        }
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
