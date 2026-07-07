import AppKit
import CasperAgents
import CasperCore
import CasperGhostty
import CasperGit
import Foundation
import Observation
import SwiftUI
import UserNotifications

/// The single owner of runtime UI state and the bridge from the non-observable
/// core types to SwiftUI. Membership changes (add/remove folder) persist
/// synchronously; high-frequency agent-state changes (Task 4) debounce.
@MainActor
@Observable
final class AppModel {
    private(set) var spaces: [Space]
    var selectedWorkspaceID: UUID?

    /// Observable revision token bumped when the selected workspace's folder
    /// changes on disk. The diff badge and diff surface re-pull on its change,
    /// giving them a live refresh without knowing about the filesystem watcher.
    private(set) var diffRevision = 0

    /// A one-shot request to scroll a workspace's diff view to a file. `nonce`
    /// makes repeated requests for the same file distinct so the view re-scrolls.
    struct DiffScrollTarget: Equatable {
        let workspaceID: UUID
        let file: String
        let nonce: Int
    }
    /// Set by `controlOpenDiff` / read by `DiffSurfaceView`. Observable so the
    /// view reacts; not part of any persisted model.
    private(set) var diffScrollTarget: DiffScrollTarget?
    @ObservationIgnored private var diffScrollNonce = 0

    /// FSEvents watcher for the selected workspace's worktree, or nil when
    /// nothing is selected. Reconfigured on every selection change.
    @ObservationIgnored private var worktreeWatcher: DirectoryWatching?

    /// Second, narrow FSEvents watcher rooted at the selected Git repo's reflog
    /// directory (`<gitdir>/logs`), or nil for a non-Git selection. It exists
    /// because `worktreeWatcher` deliberately excludes `.git` to dodge the event
    /// storm from Git's high-frequency internal writes — but a `git commit` only
    /// writes inside `.git` (index, HEAD, refs, logs) and touches no working-tree
    /// file, so it would otherwise slip past the diff refresh. `logs/HEAD` is
    /// appended on every HEAD-moving op (commit, checkout, reset, merge, rebase)
    /// yet is never written by `git status`/`add`/`diff`, making it a low-churn
    /// commit signal with no storm. Reconfigured on every selection change.
    @ObservationIgnored private var gitMetaWatcher: DirectoryWatching?

    /// Builds the watcher for the selected worktree. Injectable so tests can
    /// substitute a stub; the default builds the real FSEvents-backed watcher.
    @ObservationIgnored
    var makeWorktreeWatcher: (
        _ path: String, _ excluding: [String], _ onChange: @escaping @Sendable () -> Void
    ) -> DirectoryWatching? = { path, excluding, onChange in
        DirectoryWatcher(path: path, excluding: excluding, onChange: onChange)
    }

    /// Coalesces filesystem-change bursts (builds, save-all) into a single
    /// `diffRevision` bump.
    @ObservationIgnored private let diffDebouncer = Debouncer(delay: 0.2)

    /// The surface that last became first responder (runtime-only, not persisted).
    var focusedSurfaceID: UUID?

    /// The surface currently being dragged by its grip, or nil. Set on drag begin/end.
    var draggingSurfaceID: UUID?
    /// The pane currently under the drag and the zone the drop would use. One at a
    /// time; cleared whenever the drag ends so no highlight can get stuck.
    var dropHoverTarget: UUID?
    var dropHoverZone: LayoutTree.DropZone?

    /// Retains the View menu's `NSMenuDelegate` bridge — `NSMenu.delegate` is
    /// unowned, so without this the delegate would be deallocated right after
    /// `viewMenuItem()` returns and `menuNeedsUpdate` would never fire, leaving
    /// the split items stuck at their initial enabled state.
    var viewMenuDelegate: ViewMenuDelegate?

    /// Retains the File menu's `NSMenuDelegate` bridge — same reasoning as
    /// `viewMenuDelegate`, but for the merge/delete workspace items instead of
    /// the pane splits.
    var fileMenuDelegate: FileMenuDelegate?

    func beginPaneDrag(_ surfaceID: UUID) { draggingSurfaceID = surfaceID }
    func endPaneDrag() { draggingSurfaceID = nil; dropHoverTarget = nil; dropHoverZone = nil }
    func setDropHover(target: UUID, zone: LayoutTree.DropZone) {
        guard target != draggingSurfaceID else { return }  // don't highlight the source pane
        dropHoverTarget = target
        dropHoverZone = zone
    }
    func clearDropHover(target: UUID) {
        if dropHoverTarget == target {
            dropHoverTarget = nil
            dropHoverZone = nil
        }
    }

    @ObservationIgnored private let sessionStore: SessionStore
    @ObservationIgnored private var portAllocator: PortAllocator
    @ObservationIgnored let sessionIdentity: SessionIdentity

    @ObservationIgnored private var saveWorkItem: DispatchWorkItem?

    /// Whether the app's window currently has key focus. Injectable for tests.
    @ObservationIgnored var isWindowKey: () -> Bool = { NSApp?.keyWindow != nil }

    /// Re-probe a folder path for Git backing. Injectable for tests.
    @ObservationIgnored var gitReprobe: (String) -> WorkspaceFactory.GitInfo? = {
        AppModel.gitProbePath($0)
    }

    /// Test hook fired after each successful/attempted persist. nil in production.
    @ObservationIgnored var onPersistForTest: (() -> Void)?

    /// Delivers a local notification. Injectable for tests; the default posts a
    /// best-effort `UserNotifications` request. Skipped entirely when the process
    /// has no bundle identifier (a bare `swift run` executable): on macOS 26
    /// `UNUserNotificationCenter.current()` aborts rather than no-ops without a
    /// bundle, so guarding here keeps `make dev` runs from crashing on the first
    /// hook notification.
    @ObservationIgnored var deliverNotification: (String, String) -> Void = { title, body in
        guard Bundle.main.bundleIdentifier != nil else { return }
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
    @ObservationIgnored var controlSocketPath: String?

    /// Live surface views, keyed by surface id. Holds terminal
    /// (`GhosttySurfaceView`) and browser (`WKWebView`) views. Persisting these
    /// across SwiftUI rebuilds keeps each PTY or web page alive when the layout
    /// tree is restructured.
    @ObservationIgnored private var surfaceViews: [UUID: NSView] = [:]

    /// Live browser coordinators, keyed by surface id. Each owns a browser
    /// surface's `WKWebView` and navigation state; caching them here keeps the
    /// web page and address alive across SwiftUI rebuilds.
    @ObservationIgnored private var browserCoordinators: [UUID: BrowserCoordinator] = [:]

    /// Per-workspace debounce/`done`-derivation state for the terminal-scraping
    /// agent detector. `AgentStateResolver` is a value type carried across ticks,
    /// so each workspace owns its own copy. Runtime-only; never persisted.
    @ObservationIgnored private var agentResolvers: [UUID: AgentStateResolver] = [:]

    /// Workspaces where `casper status set` took over: detection is suppressed
    /// for them and the explicit value is authoritative. Transient — an in-memory
    /// set, never persisted, so it naturally resets to "detection" on relaunch.
    @ObservationIgnored private var explicitAuthority: Set<UUID> = []

    /// The repeating driver for `runAgentDetectionTick()`. GUI-only: started from
    /// the app lifecycle (`AppDelegate`), never from `init`, so unit tests that
    /// build an `AppModel` directly don't spin a background loop. Stored so it can
    /// be cancelled on teardown and so a second `startAgentDetection()` is a no-op.
    @ObservationIgnored private var agentDetectionTask: Task<Void, Never>?

    /// The one instance shared by the SwiftUI scene (`CasperApp`) and the
    /// AppKit lifecycle (`AppDelegate`). Loads the persisted session from its
    /// default location, falling back to a fresh, temp-backed store if the
    /// default location itself cannot be determined.
    @MainActor static let shared = makeShared()

    @MainActor
    static func makeShared() -> AppModel {
        let identity = AppLaunch.sessionIdentity
        let allocator = PortAllocator(startBase: PortAllocator.randomStartBase())
        do {
            let url = try SessionStore.defaultURL(session: identity)
            let store = SessionStore(fileURL: url)
            let session = try store.load()
            return AppModel(sessionStore: store, portAllocator: allocator,
                            session: session, sessionIdentity: identity)
        } catch {
            CasperLog.app.failure("failed to load session, starting fresh", error)
            let fallback = SessionStore(
                fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("casper-session\(identity.pathSuffix).json"))
            return AppModel(sessionStore: fallback, portAllocator: allocator,
                            sessionIdentity: identity)
        }
    }

    /// Spaces sorted by `name` (locale-aware, case-insensitive), matching the
    /// comparator `Space.orderedWorkspaces` already uses for its own workspaces.
    /// Keeping `spaces` sorted here — rather than computing a separate display
    /// order — means every other reader (sidebar, `allWorkspaces`,
    /// `workspaceShortcutNumbers`, and `session.json` on persist) gets
    /// alphabetical order for free.
    private static func sortedByName(_ spaces: [Space]) -> [Space] {
        spaces.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    init(
        sessionStore: SessionStore,
        portAllocator: PortAllocator = PortAllocator(),
        session: Session = Session(),
        sessionIdentity: SessionIdentity = .default
    ) {
        self.sessionStore = sessionStore
        self.portAllocator = portAllocator
        self.sessionIdentity = sessionIdentity
        self.spaces = Self.sortedByName(session.spaces)
        // Restore the persisted selection when it still resolves to a live
        // workspace; otherwise fall back to the first workspace of the first
        // Space (fresh-session behavior).
        let restored = session.selectedWorkspaceID.flatMap { id in
            spaces.contains { $0.workspaces.contains { $0.id == id } } ? id : nil
        }
        let selected = restored ?? spaces.first?.workspaces.first?.id
        self.selectedWorkspaceID = selected
        if let selected,
           let si = spaces.firstIndex(where: { $0.workspaces.contains { $0.id == selected } }),
           let ws = spaces[si].workspaces.first(where: { $0.id == selected }) {
            self.focusedSurfaceID = LayoutTree.surfaceIDs(ws.layout).first
            // The restored selection must be visible: expand its owning Space.
            // `init` runs before the view exists, so mutate directly (no animation).
            spaces[si].isCollapsed = false
        }
        // Reserve restored port blocks so a later allocate() never collides.
        for space in session.spaces {
            for ws in space.workspaces { self.portAllocator.reserve(ws.portBase) }
        }
        // `isGitRepo` is not persisted: every decoded Space arrives non-Git, so
        // resolve each Space's Git backing now by probing its folder. Runs ONCE at
        // startup — not on a timer — so it does not reintroduce the removed
        // heartbeat poll. Then arm the watcher for the restored selection (set
        // directly above, not through selectWorkspace).
        resolveGitBacking()
        reconfigureWorktreeWatcher()
    }

    deinit {
        worktreeWatcher?.stop()
        gitMetaWatcher?.stop()
        agentDetectionTask?.cancel()
    }

    var isEmpty: Bool { spaces.allSatisfy { $0.workspaces.isEmpty } }

    /// All workspaces across every Space, in sidebar order.
    var allWorkspaces: [Workspace] { spaces.flatMap(\.workspaces) }

    /// Maps eligible workspaces to their `Cmd+N` shortcut (1-9), following
    /// sidebar display order: `spaces` in list order, collapsed spaces
    /// skipped entirely (their workspaces aren't visible, so they get no
    /// shortcut while hidden), each visible space's workspaces in
    /// `orderedWorkspaces` order. Feeds both the sidebar hint label and
    /// `selectWorkspace(atShortcutNumber:)` — the two can never drift apart
    /// since they share this one lookup.
    var workspaceShortcutNumbers: [UUID: Int] {
        var numbers: [UUID: Int] = [:]
        var next = 1
        for space in spaces where !space.isCollapsed {
            for workspace in space.orderedWorkspaces {
                guard next <= 9 else { return numbers }
                numbers[workspace.id] = next
                next += 1
            }
        }
        return numbers
    }

    /// Whether the sidebar should show the `Cmd+N` shortcut hint in place of
    /// the notification bubble. Set by `WorkspaceShortcutKeyMonitor` while
    /// Cmd is held past the reveal delay.
    var showWorkspaceShortcutHints: Bool = false

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
        spaces = Self.sortedByName(spaces)
        selectWorkspace(space.workspaces.first?.id)
        persist()
    }

    func removeSpace(id: UUID) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        let removed = spaces.remove(at: index)
        for ws in removed.workspaces {
            portAllocator.release(ws.portBase)
            discardSurfaceViews(LayoutTree.surfaceIDs(ws.layout))
        }
        if let sel = selectedWorkspaceID, removed.workspaces.contains(where: { $0.id == sel }) {
            selectWorkspace(spaces.first?.workspaces.first?.id)
        }
        persist()
    }

    /// Flip a Space's collapsed state (sidebar header disclosure) and persist.
    func toggleSpaceCollapsed(id: UUID) {
        guard let i = spaces.firstIndex(where: { $0.id == id }) else { return }
        // Drive the state change inside `withAnimation` so the sidebar's
        // conditional rows animate their insertion/removal (and the header
        // chevron's rotation) in one coherent `.snappy` transaction.
        withAnimation(.snappy) {
            spaces[i].isCollapsed.toggle()
        }
        persist()
    }

    /// The given path if free, otherwise the first `-<n>` suffixed sibling that does
    /// not yet exist (`…-my-feature`, `…-my-feature-2`, `…-my-feature-3`, …). Keeps
    /// worktree creation from failing when the target directory is already taken.
    private func availableWorktreePath(_ basePath: String) -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: basePath) else { return basePath }
        var suffix = 2
        while fm.fileExists(atPath: "\(basePath)-\(suffix)") { suffix += 1 }
        return "\(basePath)-\(suffix)"
    }

    /// Create a linked workspace (new branch + worktree at a visible sibling of the
    /// repo folder, `<parent>/<repo>-<branch>`) in a Git Space. Placing worktrees
    /// outside the repo keeps them naturally untracked. When the sibling directory
    /// name is already taken, a numeric suffix (`-2`, `-3`, …) is appended so
    /// creation still succeeds; the branch name is left unchanged. Returns false when
    /// the Space is missing, not a Git repo, the name is unusable, or the worktree
    /// cannot be created.
    @discardableResult
    func addLinkedWorkspace(spaceID: UUID, name: String) -> Bool {
        if case .success = createLinkedWorkspace(spaceID: spaceID, name: name, base: nil) {
            return true
        }
        return false
    }

    /// Create a linked workspace (new branch + worktree at `<parent>/<repo>-<branch>`)
    /// in a Git Space. `base` overrides the fork point; nil derives it from the
    /// primary workspace's branch (the prior behavior). Returns the new workspace or
    /// a human-readable error.
    func createLinkedWorkspace(
        spaceID: UUID, name: String, base baseOverride: String?
    ) -> Result<Workspace, WorkspaceCreationError> {
        guard let si = spaces.firstIndex(where: { $0.id == spaceID }) else {
            return .failure(WorkspaceCreationError(message: "space not found"))
        }
        guard spaces[si].isGitRepo else {
            return .failure(WorkspaceCreationError(message: "space is not a Git repository"))
        }
        guard let branch = GitBranchName.sanitize(name) else {
            return .failure(WorkspaceCreationError(message: "invalid branch name: \(name)"))
        }
        let folder = spaces[si].folderPath
        let base = baseOverride ?? (spaces[si].workspaces.first?.branch ?? "")
        let folderURL = URL(fileURLWithPath: folder)
        let basePath = folderURL.deletingLastPathComponent()
            .appendingPathComponent(folderURL.lastPathComponent + "-" + branch).path
        let worktreePath = availableWorktreePath(basePath)

        let portBase: Int
        do { portBase = try portAllocator.allocate() } catch {
            CasperLog.app.failure("cannot add workspace: no free port block", error)
            return .failure(WorkspaceCreationError(message: "no free port block"))
        }
        do {
            _ = try WorktreeManager.create(
                repoPath: folder, name: branch, worktreePath: worktreePath,
                base: base.isEmpty ? nil : base)
        } catch {
            portAllocator.release(portBase)
            CasperLog.app.failure("worktree creation failed", error)
            return .failure(
                WorkspaceCreationError(message: "worktree creation failed: \(error.localizedDescription)"))
        }
        let ws = WorkspaceFactory.makeLinkedWorkspace(
            name: branch, worktreePath: worktreePath, branch: branch,
            baseBranch: base, portBase: portBase)
        spaces[si].workspaces.append(ws)
        selectWorkspace(ws.id)
        persist()
        return .success(ws)
    }

    /// Drop a linked workspace (never a primary); releases its port, leaves the
    /// worktree and branch on disk.
    func removeWorkspace(id: UUID) {
        guard let at = locate(id) else { return }
        guard spaces[at.space].workspaces[at.workspace].kind == .linked else { return }
        let ws = spaces[at.space].workspaces.remove(at: at.workspace)
        portAllocator.release(ws.portBase)
        discardSurfaceViews(LayoutTree.surfaceIDs(ws.layout))
        // Prune the transient agent-state maps so they don't grow unbounded across a
        // long session (both the close and control-destroy paths funnel through here).
        explicitAuthority.remove(id)
        agentResolvers[id] = nil
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
        // Re-arm before the early return so a nil/non-Git selection stops the watcher.
        reconfigureWorktreeWatcher()
        guard let id, let ws = workspace(id: id) else { return }
        // A selected workspace must be visible: expand its owning Space if it was
        // collapsed. Only mutate when actually collapsed, so an already-expanded
        // Space doesn't run a redundant no-op animation.
        if let si = spaces.firstIndex(where: { $0.workspaces.contains { $0.id == id } }),
           spaces[si].isCollapsed {
            withAnimation(.snappy) { spaces[si].isCollapsed = false }
        }
        focusedSurfaceID = LayoutTree.surfaceIDs(ws.layout).first
        focusActiveSurfaceView()
        clearNotificationForFocusedWorkspace()
        persist()
    }

    /// Switches to the workspace at `number` (1-9) in `workspaceShortcutNumbers`
    /// order. A number with no matching workspace (e.g. `Cmd+7` with only four
    /// workspaces) is a no-op.
    func selectWorkspace(atShortcutNumber number: Int) {
        guard let match = workspaceShortcutNumbers.first(where: { $0.value == number })?.key else { return }
        selectWorkspace(match)
    }

    /// Reconcile the current selection's Git backing (promote-only — safe at
    /// launch/selection time) and then (re)arm its watcher. Promotion picks up a
    /// `.git` that appeared before selection; demotion never happens here, only on
    /// a live filesystem event, so a transient probe failure can't drop a Space's
    /// Git backing. Called from `selectWorkspace(_:)` and `init`.
    private func reconfigureWorktreeWatcher() {
        if let id = selectedWorkspaceID, let at = locate(id) {
            promoteSpaceIfGitInitialized(spaceIndex: at.space)
        }
        armWorktreeWatcher()
    }

    /// (Re)build the FSEvents watcher for the current selection from the CURRENT
    /// Git-backing/gitignore state. Stops any prior watcher, then starts a fresh
    /// one on the selected worktree regardless of Git-backing — a degenerate Space
    /// must still be watched so it can detect gaining a `.git`. Excludes `.git`
    /// (for a Git Space) and gitignored directories. Each coalesced change hops to
    /// the main actor and, after the debounce window, drives
    /// `handleSelectedWorktreeChange`. Pure wiring: no promotion/demotion here. A
    /// nil selection leaves the watcher stopped.
    private func armWorktreeWatcher() {
        worktreeWatcher?.stop()
        worktreeWatcher = nil
        gitMetaWatcher?.stop()
        gitMetaWatcher = nil
        guard let id = selectedWorkspaceID, let at = locate(id) else { return }
        let ws = spaces[at.space].workspaces[at.workspace]
        let path = ws.worktreePath
        var exclusions: [String] = []
        if spaces[at.space].isGitRepo {
            exclusions.append(path + "/.git")
            if let repo = try? Repository.open(atPath: path) {
                exclusions.append(contentsOf: (try? repo.ignoredTopLevelDirectories()) ?? [])
            }
        }
        // FSEventStreamSetExclusionPaths accepts at most 8 paths; .git stays first.
        if exclusions.count > 8 { exclusions = Array(exclusions.prefix(8)) }
        worktreeWatcher = makeWorktreeWatcher(path, exclusions) { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.diffDebouncer.schedule { [weak self] in
                        self?.handleSelectedWorktreeChange()
                    }
                }
            }
        }
        // Commit detection: watch the resolved gitdir's reflog directory, which the
        // `.git`-excluded worktree watcher above can't see. `gitDirPath` carries a
        // trailing slash and, for a linked worktree, resolves to
        // `<maindir>/.git/worktrees/<name>/`, so its `logs/HEAD` reflog is the one
        // that moves on this worktree's commits. Reuse `makeWorktreeWatcher` (the
        // test injection seam) with no exclusions, routing through the same debounced
        // hop as the primary watcher. Degrades gracefully to nil if the repo can't be
        // opened or the logs dir can't be watched.
        if spaces[at.space].isGitRepo, let repo = try? Repository.open(atPath: path) {
            let logsPath = repo.gitDirPath + "logs"
            gitMetaWatcher = makeWorktreeWatcher(logsPath, []) { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.diffDebouncer.schedule { [weak self] in
                            self?.handleSelectedWorktreeChange()
                        }
                    }
                }
            }
        }
    }

    /// Debounced reaction to a filesystem change in the selected worktree. This
    /// runs only from a live FSEvents change, so it is the one place allowed to
    /// flip a Space's Git backing in either direction: promote a degenerate Space
    /// that just gained a `.git`, or demote a Git Space whose `.git` was removed.
    /// A flip changes the exclusion set, so re-arm the watcher; then bump the diff
    /// revision so the badge and diff view refresh.
    ///
    /// Deleting the whole `.git` directory fires a root-level FSEvents change even
    /// though `.git` is excluded — exclusions suppress events *under* `.git`, not
    /// the parent-directory change when `.git` itself is removed — so this handler
    /// is still reached on demotion.
    private func handleSelectedWorktreeChange() {
        guard let id = selectedWorkspaceID, let at = locate(id) else { return }
        let flipped = spaces[at.space].isGitRepo
            ? demoteSpaceIfGitRemoved(spaceIndex: at.space)
            : promoteSpaceIfGitInitialized(spaceIndex: at.space)
        if flipped { armWorktreeWatcher() }   // backing changed → exclusions changed → re-arm
        diffRevision += 1
    }

    /// Determine every Space's Git backing at load time. `isGitRepo` is no longer
    /// persisted, so each decoded Space arrives non-Git; probe its folder to set
    /// the runtime flag and adopt HEAD's branch on the primary workspace. Runs
    /// ONCE at startup (not on a timer). Uses the injectable `gitReprobe`.
    ///
    /// A transient probe failure here shows a real repo as non-Git for the
    /// session — acceptable now that the flag is computed rather than stored; the
    /// live FSEvents path (promote/demote) still corrects it on the next change.
    private func resolveGitBacking() {
        for si in spaces.indices {
            guard !spaces[si].workspaces.isEmpty,
                  let info = gitReprobe(spaces[si].folderPath) else { continue }
            spaces[si].isGitRepo = true
            spaces[si].workspaces[0].branch = info.branch
        }
    }

    /// Re-probe a not-yet-Git space and, if it now has a repository, promote it:
    /// mark it Git-backed, adopt HEAD's branch on its primary workspace, and
    /// persist. Returns whether a promotion happened. Reuses the injectable
    /// `gitReprobe`. (Formerly driven by the heartbeat poll.)
    @discardableResult
    func promoteSpaceIfGitInitialized(spaceIndex si: Int) -> Bool {
        guard spaces.indices.contains(si), !spaces[si].isGitRepo,
              !spaces[si].workspaces.isEmpty,
              let info = gitReprobe(spaces[si].folderPath) else { return false }
        spaces[si].isGitRepo = true
        spaces[si].workspaces[0].branch = info.branch
        persist()
        return true
    }

    /// Demote a Git-backed space whose repository has disappeared (e.g. its `.git`
    /// was deleted): mark it non-Git and clear the primary workspace's branch, then
    /// persist. Returns whether a demotion happened. Only ever called from a live
    /// filesystem-change event — never from a launch/selection-time probe, where a
    /// transient read failure must not be mistaken for `.git` removal.
    @discardableResult
    func demoteSpaceIfGitRemoved(spaceIndex si: Int) -> Bool {
        guard spaces.indices.contains(si), spaces[si].isGitRepo,
              !spaces[si].workspaces.isEmpty,
              gitReprobe(spaces[si].folderPath) == nil else { return false }
        spaces[si].isGitRepo = false
        spaces[si].workspaces[0].branch = ""   // degenerate primaries carry an empty branch
        persist()
        return true
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
    /// Preserves the active tab when a background tab is closed. Closing the last
    /// surface tears down the workspace non-destructively: a linked workspace is
    /// dropped (worktree/branch left on disk); a primary closes its whole Space,
    /// unless linked workspaces depend on that Space, in which case the Space stays
    /// and the primary is re-seeded with a fresh terminal.
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
        // Last surface in the workspace was closed. Discard its views, then close
        // the workspace non-destructively — never taking down anything that depends
        // on it (its worktree/branch, or a Space's linked workspaces).
        let ws = spaces[at.space].workspaces[at.workspace]
        discardSurfaceViews(LayoutTree.surfaceIDs(ws.layout))
        switch ws.kind {
        case .linked:
            // A linked workspace stands alone: drop it (its worktree and branch stay
            // on disk). removeWorkspace reassigns the selection.
            if wasFocused { focusedSurfaceID = nil }
            removeWorkspace(id: ws.id)
        case .primary where spaces[at.space].workspaces.contains(where: { $0.kind == .linked }):
            // The primary anchors the Space and its linked workspaces depend on it,
            // so removing the whole Space would destroy them too. Keep the Space and
            // re-seed the primary with a fresh terminal to keep it alive.
            let fresh = newTerminalSurface(cwd: ws.worktreePath)
            spaces[at.space].workspaces[at.workspace].layout = .leaf(fresh)
            if wasFocused || selectedWorkspaceID == ws.id { focusedSurfaceID = fresh.id }
            persist()
            focusActiveSurfaceView()
        case .primary:
            // No linked workspaces depend on this primary: closing its last pane
            // closes the whole Space. removeSpace reassigns the selection.
            if wasFocused { focusedSurfaceID = nil }
            removeSpace(id: spaces[at.space].id)
        }
    }

    /// Relocate an existing surface to sit beside `targetID` on the side implied
    /// by `zone` (the drag-and-drop drop). Mirrors `insertSurfaceBySplitting`'s
    /// tail, but reuses the SAME `Surface` value (same id), so the cached
    /// `GhosttySurfaceView`/PTY survives untouched — no view is discarded or
    /// recreated. Both surfaces must live in the same (space, workspace); a
    /// cross-workspace move (or any degenerate move) is a no-op.
    func moveSurface(_ surfaceID: UUID, toTarget targetID: UUID, zone: LayoutTree.DropZone) {
        guard let at = locateSurface(surfaceID), let targetAt = locateSurface(targetID),
              targetAt == at
        else { return }
        guard let (layout, newFocus) = LayoutTree.move(
            spaces[at.space].workspaces[at.workspace].layout,
            surfaceID: surfaceID, toTarget: targetID, direction: zone.direction)
        else { return }
        spaces[at.space].workspaces[at.workspace].layout = layout
        focusedSurfaceID = newFocus
        persist()
        focusActiveSurfaceView()
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
            onClose: { [weak self] id in self?.applyCloseSurface(id) },
            onContextMenu: { [weak self, id = surface.id] _ in self?.paneContextMenu(for: id) })
        surfaceViews[surface.id] = view
        return view
    }

    /// Visible viewport text of a live terminal surface, or nil if it has no
    /// live Ghostty view. Read-only; used by agent-state detection.
    func surfaceViewportText(_ surfaceID: UUID) -> String? {
        (surfaceViews[surfaceID] as? GhosttySurfaceView)?.readViewportText()
    }

    /// OSC window title of a live terminal surface, or nil if it has no live
    /// Ghostty view. Read-only; used by agent-state detection.
    func surfaceOSCTitle(_ surfaceID: UUID) -> String? {
        (surfaceViews[surfaceID] as? GhosttySurfaceView)?.readOSCTitle()
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

    /// Whether the workspace's owning Space is a Git repository.
    func isWorkspaceGitBacked(_ workspace: Workspace) -> Bool {
        space(for: workspace)?.isGitRepo ?? false
    }

    /// Memoizes the last `computeDiff` result so the diff surface and the toolbar
    /// summary don't each recompute it for the same state. Keyed by the workspace
    /// id and the `diffRevision` at compute time, so a new selection or a
    /// filesystem-change bump invalidates it without an explicit clear.
    @ObservationIgnored private var cachedDiff: (workspaceID: UUID, revision: Int, diff: GitDiff?)?

    /// Compute the working-tree-vs-HEAD diff of a workspace's worktree. Returns nil
    /// when the workspace is not Git-backed or the diff fails.
    func computeDiff(for workspace: Workspace) -> GitDiff? {
        if let cached = cachedDiff, cached.workspaceID == workspace.id, cached.revision == diffRevision {
            return cached.diff
        }
        // Runs synchronously on the main actor: `Repository` is non-Sendable and
        // main-actor-confined, so an off-actor move would force this API to async
        // and thread through the diff and toolbar views. The per-revision cache
        // above keeps the cost to one diff per selection or filesystem change.
        let diff: GitDiff?
        do {
            let repo = try Repository.open(atPath: workspace.worktreePath)
            diff = try repo.diffWorkdirToHead()
        } catch {
            CasperLog.app.failure("diff failed", error)
            diff = nil
        }
        cachedDiff = (workspace.id, diffRevision, diff)
        return diff
    }

    /// The workspace's working-tree-vs-HEAD line counts, or nil when not
    /// Git-backed or the diff fails. Feeds the detail toolbar's `+INS −DEL`.
    func diffSummary(for workspace: Workspace) -> (insertions: Int, deletions: Int)? {
        computeDiff(for: workspace).map { ($0.insertions, $0.deletions) }
    }

    /// Files larger than this are left un-highlighted (neutral) to keep the diff
    /// view responsive. (bytes)
    private static let maxHighlightBytes = 512 * 1024

    /// The full UTF-8 text of `path` in the workspace's HEAD commit, or nil when
    /// the path is empty/absent, the blob is binary, exceeds `maxHighlightBytes`,
    /// or the read fails. This is the "before" side of the diff, feeding syntax
    /// highlighting.
    func headFileText(for workspace: Workspace, path: String) -> String? {
        guard !path.isEmpty else { return nil }
        do {
            let repo = try Repository.open(atPath: workspace.worktreePath)
            guard let text = try repo.fileTextAtHead(path: path) else { return nil }
            // Mirror worktreeFileText's cap: keep oversized blobs out of the highlighter.
            guard text.utf8.count <= Self.maxHighlightBytes else { return nil }
            return text
        } catch {
            CasperLog.app.failure("read HEAD file text failed", error)
            return nil
        }
    }

    /// The full UTF-8 text of `path` on disk in the workspace's worktree, or nil
    /// when the path is empty, the file is missing/unreadable, exceeds
    /// `maxHighlightBytes`, or is not valid UTF-8. This is the "after" side of the
    /// diff, feeding syntax highlighting. Never throws.
    func worktreeFileText(for workspace: Workspace, path: String) -> String? {
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: workspace.worktreePath).appendingPathComponent(path)
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            if let size, size > Self.maxHighlightBytes { return nil }
            let data = try Data(contentsOf: url)
            guard data.count <= Self.maxHighlightBytes else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    /// Rewrite a browser surface's persisted URL (address-bar navigation).
    /// Searches the layout trees first; when the surface isn't in any layout, it
    /// falls back to each workspace's inspector browser, which lives outside the
    /// tree.
    ///
    /// `syncNav` fires on both `didCommit` and `didFinish`, so persistence is
    /// debounced via `scheduleSave()` and skipped entirely when the committed URL
    /// already matches the stored one — a page load must not thrash the session file.
    func setBrowserURL(_ surfaceID: UUID, _ url: URL) {
        if let at = indexPair(where: { $0.inspector.browser.id == surfaceID }) {
            if case .browser(let current) = spaces[at.space].workspaces[at.workspace].inspector.browser.kind,
               current == url { return }
            spaces[at.space].workspaces[at.workspace].inspector.browser =
                Surface(id: surfaceID, kind: .browser(url: url))
            scheduleSave()
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

    func persist() {
        do {
            try sessionStore.save(Session(spaces: spaces, selectedWorkspaceID: selectedWorkspaceID))
        } catch {
            CasperLog.app.failure("failed to persist session", error)
        }
        onPersistForTest?()
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

    /// The per-surface environment injected into a terminal so the `casper` CLI
    /// resolves and the agent sees its reserved ports.
    func surfaceConfiguration(
        for workspace: Workspace, terminal: Surface
    ) -> GhosttySurfaceConfiguration {
        guard case .terminal(let cwd, let command) = terminal.kind else {
            return GhosttySurfaceConfiguration()
        }
        var config = GhosttySurfaceConfiguration(workingDirectory: cwd, command: command)
        config.environment = ClaudeCodeAdapter.surfaceEnvironment(
            workspaceId: workspace.id,
            portBase: workspace.portBase,
            casperDirectory: casperDirectory,
            basePath: ProcessInfo.processInfo.environment["PATH"],
            controlSocketPath: controlSocketPath,
            sessionName: sessionIdentity.name
        )
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

    /// Error carrying a human-readable reason for a failed workspace creation.
    struct WorkspaceCreationError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// Error carrying a human-readable reason for a rejected `diff open` request.
    struct DiffOpenError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// Error carrying a human-readable reason for a rejected `workspace delete`.
    struct WorkspaceDeleteError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// The outcome of `closeWorkspace(id:)`, distinguishing a merge failure (nothing
    /// touched) from a cleanup failure (the merge succeeded, but disk cleanup didn't) —
    /// the confirmation presenter shows a different title/message for each.
    enum WorkspaceCloseOutcome: Equatable, Sendable {
        case success
        case mergeFailed(message: String)
        case cleanupFailed(message: String)
    }

    // MARK: - Agent-state detection
    //
    // The implicit producer of `agentState`: Casper owns each terminal's PTY, so
    // it scrapes the visible viewport and infers what the agent is doing. The pure
    // policy lives in CasperCore (`AgentDetectionRuleSet`, `AgentSignal`,
    // `AgentStateResolver`); this is only the wiring. It complements — and always
    // yields to — the explicit `casper status set` path (see the authority latch
    // in `controlSetAgentState`). See `.superpowers/themes/agent-state-detection.md`.

    /// Start the periodic terminal-scraping detector on a ~0.25s cadence.
    /// Idempotent: a second call while a loop is already running is a no-op.
    func startAgentDetection() {
        guard agentDetectionTask == nil else { return }
        agentDetectionTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.runAgentDetectionTick()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// Stop the periodic detector (app teardown).
    func stopAgentDetection() {
        agentDetectionTask?.cancel()
        agentDetectionTask = nil
    }

    /// One detection pass over every workspace. For each workspace not under
    /// explicit authority, scrape its live terminal viewports, aggregate the raw
    /// signals, run the resolver, and write the result. A workspace with nothing
    /// readable this tick (no live surface view) is left untouched rather than
    /// forced to `unknown`, so switching a workspace off-screen doesn't wipe its
    /// last known state.
    func runAgentDetectionTick() {
        for space in spaces {
            for ws in space.workspaces {
                if explicitAuthority.contains(ws.id) { continue }  // detection stopped for W

                let terminalIDs = LayoutTree.surfaces(ws.layout).compactMap { surface -> UUID? in
                    guard case .terminal = surface.kind else { return nil }
                    return surface.id
                }
                let signals = terminalIDs.compactMap { id -> AgentSignal? in
                    guard let text = surfaceViewportText(id) else { return nil }  // no live view ⇒ skip
                    let rules = AgentDetectionRuleSet.claudeCode
                    let viewport = rules.signal(fromViewport: text)
                    let title = surfaceOSCTitle(id).map { rules.signal(fromTitle: $0) } ?? .absent
                    // Roll the viewport and title signals together (blocked > working > idle >
                    // absent): the title carries the primary "working" spinner, the viewport
                    // carries "blocked" prompts, and blocked wins if both are present.
                    return AgentSignal.aggregate([viewport, title])
                }
                if signals.isEmpty { continue }  // nothing readable ⇒ leave W's state untouched

                let aggregated = AgentSignal.aggregate(signals)
                let seen = (selectedWorkspaceID == ws.id)
                var resolver = agentResolvers[ws.id] ?? AgentStateResolver()
                let state = resolver.resolve(signal: aggregated, seen: seen)
                agentResolvers[ws.id] = resolver  // persist the mutated resolver back
                setDetectedAgentState(state, for: ws.id)
            }
        }
    }

    /// Write a *detected* agent state. Distinct from the explicit
    /// `controlSetAgentState`: it must NOT grant authority. Writes only when the
    /// value actually changes, so a steady detection stream doesn't thrash the UI.
    /// Exposed (internal, not private) as a test seam so the notify-wiring can be
    /// unit-tested directly, like `isUnderExplicitAuthority` / `runAgentDetectionTick`.
    func setDetectedAgentState(_ state: AgentState, for workspaceID: UUID) {
        guard let at = locate(workspaceID),
              spaces[at.space].workspaces[at.workspace].agentState != state else { return }
        // agentState is transient (deliberately not encoded by Session's Codable),
        // so the @Observable mutation refreshes the sidebar with no need to persist.
        spaces[at.space].workspaces[at.workspace].agentState = state
        // A detected transition into an attention state raises the same notification
        // `casper notify` would — a real macOS notification plus the sidebar dot — so
        // the user is alerted without installing any agent hook. Reached only on an
        // actual change thanks to the guard above (edge-triggered, no extra dedup).
        if let message = Self.notificationMessage(for: state) {
            controlRaiseNotification(message: message, for: workspaceID)
        }
    }

    /// The notification text for a detected state, or `nil` when the state needs
    /// no attention. Only `blocked` and `done` alert the user; the rest are silent.
    /// Exhaustive by design so a new `AgentState` case forces a decision here.
    private static func notificationMessage(for state: AgentState) -> String? {
        switch state {
        case .blocked: return "Waiting for your input"
        case .done: return "Task finished"
        case .working, .idle, .unknown, .error: return nil
        }
    }

    // MARK: - CLI control handlers
    //
    // Explicit, agent-agnostic state reporting and UI driving for the `casper`
    // control channel. State setters mutate the target workspace in place (never
    // changing the current selection); the model is `@Observable`, so the sidebar
    // updates automatically. All run on the main actor.

    @discardableResult
    func controlSetAgentState(_ state: AgentState, for workspaceID: UUID) -> Bool {
        guard let at = locate(workspaceID) else { return false }
        spaces[at.space].workspaces[at.workspace].agentState = state
        // The explicit CLI path is the ONLY place authority is granted: once an
        // agent reports its own state, terminal-scraping detection steps aside for
        // this workspace. Robust authority release is deferred to a later timeout
        // mechanism.
        explicitAuthority.insert(workspaceID)
        persist()
        return true
    }

    /// Whether `workspaceID` is under explicit (CLI) authority, which suppresses
    /// terminal-scraping detection for it. Test seam for the authority latch.
    func isUnderExplicitAuthority(_ workspaceID: UUID) -> Bool {
        explicitAuthority.contains(workspaceID)
    }

    @discardableResult
    func controlSetProgress(total: Int, current: Int, label: String, for workspaceID: UUID) -> Bool {
        guard let at = locate(workspaceID),
              let todos = ProgressSynthesis.todos(total: total, current: current, label: label)
        else { return false }
        spaces[at.space].workspaces[at.workspace].todos = todos
        persist()
        return true
    }

    @discardableResult
    func controlClearProgress(for workspaceID: UUID) -> Bool {
        guard let at = locate(workspaceID) else { return false }
        spaces[at.space].workspaces[at.workspace].todos = []
        persist()
        return true
    }

    /// Raise a workspace notification. The persistent attention bubble is suppressed
    /// when the target is focused (selected AND the window is key); the macOS
    /// notification (when a message is given) is always delivered. When raised, the
    /// message (if any) is also stored on the workspace so the sidebar can display it,
    /// mirrored by `clearNotificationForFocusedWorkspace`.
    ///
    /// Returns `false` when no such workspace exists, `true` otherwise. The
    /// attention bubble is only raised when the target is not already focused; the
    /// macOS notification (when a message is given) is always delivered.
    @discardableResult
    func controlRaiseNotification(message: String?, for workspaceID: UUID) -> Bool {
        guard let at = locate(workspaceID) else { return false }
        // The attention bubble draws the eye to a workspace you are NOT looking
        // at. If the target is already focused (selected AND the window is key),
        // raising it is noise, so skip it. The macOS notification (with a message)
        // is still delivered so an explicit `--message` is never silently dropped.
        let focused = (workspaceID == selectedWorkspaceID) && isWindowKey()
        if !focused {
            spaces[at.space].workspaces[at.workspace].pendingNotification = true
            spaces[at.space].workspaces[at.workspace].pendingNotificationMessage = message
        }
        // A notification means "look at this workspace". If its owning Space is
        // collapsed, the workspace row (and any attention bubble) is hidden, so expand
        // the Space to surface it — regardless of focus, since the user may have
        // collapsed a Space that still contains the selection. Guard on isCollapsed to
        // avoid a redundant no-op animation.
        if spaces[at.space].isCollapsed {
            withAnimation(.snappy) { spaces[at.space].isCollapsed = false }
        }
        if let message {
            deliverNotification(spaces[at.space].workspaces[at.workspace].name, message)
        }
        persist()
        return true
    }

    /// Dismiss the attention bubble of the selected workspace once it is focused
    /// (selected AND the window is key). The bubble draws the eye to a workspace
    /// you are NOT looking at, so as soon as you look at it — by selecting it while
    /// the app is frontmost, or by bringing the app back to the foreground while it
    /// is already selected — it must clear. Complements `controlRaiseNotification`,
    /// which never raises the bubble on an already-focused workspace. Persists only
    /// when it actually clears a bubble, so the common no-op case is free.
    func clearNotificationForFocusedWorkspace() {
        guard let id = selectedWorkspaceID, isWindowKey(), let at = locate(id) else { return }
        guard spaces[at.space].workspaces[at.workspace].pendingNotification else { return }
        spaces[at.space].workspaces[at.workspace].pendingNotification = false
        spaces[at.space].workspaces[at.workspace].pendingNotificationMessage = nil
        persist()
    }

    /// Resolve a control-channel target selector to a workspace id. A nil selector
    /// falls back to the current selection; a non-nil selector matches by id then by
    /// name (see `ControlTargeting`).
    func controlResolveWorkspaceID(selector: String?) -> UUID? {
        guard let selector else { return selectedWorkspaceID }
        guard let matched = ControlTargeting.match(selector: selector, candidates: controlListWorkspaces())
        else { return nil }
        return UUID(uuidString: matched)
    }

    func controlListWorkspaces() -> [ControlWorkspaceInfo] {
        allWorkspaces.map {
            ControlWorkspaceInfo(id: $0.id.uuidString, name: $0.name, branch: $0.branch, path: $0.worktreePath)
        }
    }

    /// Open a new terminal in `workspaceID` by splitting its top-left surface to
    /// the right. Mirrors the toolbar's "new terminal" action, but targeted at an
    /// arbitrary (non-selected) workspace, and allows overriding the working
    /// directory (defaults to the workspace's worktree) and running a command.
    @discardableResult
    func controlOpenTerminal(in workspaceID: UUID, command: String? = nil, cwd: String? = nil) -> ControlTerminalInfo? {
        guard let ws = workspace(id: workspaceID),
              let anchor = LayoutTree.surfaceIDs(ws.layout).first,
              let at = locateSurface(anchor) else { return nil }
        let resolvedCwd = cwd ?? ws.worktreePath
        let surface = Surface.terminal(cwd: resolvedCwd, command: command)
        insertSurfaceBySplitting(
            at: at, focused: anchor, orientation: .horizontal, side: .after, surface: surface)
        return ControlTerminalInfo(id: surface.id.uuidString, cwd: resolvedCwd, command: command)
    }

    /// List the terminal surfaces of `workspaceID` in visual (depth-first) order.
    /// Non-terminal leaves (none exist in a layout today, but the filter stays
    /// defensive) are skipped.
    func controlListTerminals(in workspaceID: UUID) -> [ControlTerminalInfo] {
        guard let ws = workspace(id: workspaceID) else { return [] }
        return LayoutTree.surfaces(ws.layout).compactMap { surface in
            guard case .terminal(let cwd, let command) = surface.kind else { return nil }
            return ControlTerminalInfo(id: surface.id.uuidString, cwd: cwd, command: command)
        }
    }

    /// Close the terminal `terminalID` in `workspaceID`. Returns false when the id
    /// is malformed or is not a terminal surface of that workspace.
    func controlCloseTerminal(in workspaceID: UUID, terminalID: String?) -> Bool {
        guard let terminalID, let uuid = UUID(uuidString: terminalID),
              let ws = workspace(id: workspaceID),
              LayoutTree.surfaces(ws.layout).contains(where: { surface in
                  guard surface.id == uuid, case .terminal = surface.kind else { return false }
                  return true
              }) else { return false }
        applyCloseSurface(uuid)
        return true
    }

    /// Load `url` into `workspaceID`'s inspector browser surface and select the
    /// browser tab (expanding the panel). The browser lives ONLY in the inspector
    /// — there are no browser layout panels — so this mirrors `controlOpenDiff`.
    @discardableResult
    func controlOpenBrowser(url: URL, in workspaceID: UUID) -> Bool {
        guard let at = locate(workspaceID) else { return false }
        spaces[at.space].workspaces[at.workspace].inspector.browser = Surface(kind: .browser(url: url))
        setInspectorTab(.browser, for: workspaceID)   // selects the browser tab, expands, persists
        return true
    }

    /// Open `workspaceID`'s diff view (select the diff tab, expand the inspector).
    /// When `file` is given, validate it against the workspace's worktree — it
    /// must resolve INSIDE the worktree and exist on disk — then request the view
    /// scroll to its worktree-relative path (matching `GitDiffFile.id`). Mirrors
    /// `controlOpenBrowser`, but returns a `Result` so an invalid file surfaces as
    /// a control-channel error instead of a silent no-op.
    @discardableResult
    func controlOpenDiff(in workspaceID: UUID, file: String? = nil) -> Result<Void, DiffOpenError> {
        guard let at = locate(workspaceID) else {
            return .failure(DiffOpenError(message: "workspace not found"))
        }
        let worktree = spaces[at.space].workspaces[at.workspace].worktreePath
        if let file, !file.isEmpty {
            guard let resolved = WorkspaceFilePath.resolve(file, inWorktree: worktree) else {
                return .failure(DiffOpenError(message: "file is outside the workspace: \(file)"))
            }
            guard FileManager.default.fileExists(atPath: resolved) else {
                return .failure(DiffOpenError(message: "file does not exist: \(file)"))
            }
            setInspectorTab(.diff, for: workspaceID)
            diffScrollNonce += 1
            diffScrollTarget = DiffScrollTarget(
                workspaceID: workspaceID,
                file: WorkspaceFilePath.relative(resolved, toWorktree: worktree),
                nonce: diffScrollNonce)
        } else {
            setInspectorTab(.diff, for: workspaceID)
        }
        return .success(())
    }

    /// Create a linked workspace in the Space that owns `workspaceID` (the control
    /// channel's "create workspace" verb, targetable from any workspace in that
    /// Space, not just the primary).
    func controlCreateWorkspace(
        inSpaceOf workspaceID: UUID, branch: String, base: String?
    ) -> Result<ControlWorkspaceInfo, WorkspaceCreationError> {
        guard let ws = workspace(id: workspaceID), let space = space(for: ws) else {
            return .failure(WorkspaceCreationError(message: "no target workspace"))
        }
        return createLinkedWorkspace(spaceID: space.id, name: branch, base: base)
            .map { ControlWorkspaceInfo(id: $0.id.uuidString, name: $0.name, branch: $0.branch, path: $0.worktreePath) }
    }

    /// Destroy a LINKED workspace: prune its worktree (deletes the folder),
    /// delete its branch in the origin repo, then drop it from the UI. Refuses a
    /// primary workspace. Git cleanup runs BEFORE the UI removal so a git failure
    /// leaves the workspace intact and retryable. Pruning must precede the branch
    /// delete (a checked-out branch cannot be deleted); pruning is skipped when the
    /// worktree is already gone, and the branch delete is idempotent. Shared by the
    /// `casper workspace delete` control-channel verb and the sidebar's "Merge and
    /// Close Workspace…"/"Delete Workspace…" actions.
    @discardableResult
    private func pruneWorkspaceFromDisk(id workspaceID: UUID) -> Result<Void, WorkspaceDeleteError> {
        guard let at = locate(workspaceID) else {
            return .failure(WorkspaceDeleteError(message: "workspace not found"))
        }
        guard spaces[at.space].workspaces[at.workspace].kind == .linked else {
            return .failure(WorkspaceDeleteError(message: "cannot delete the primary workspace"))
        }
        let repoPath = spaces[at.space].folderPath
        let branch = spaces[at.space].workspaces[at.workspace].branch
        do {
            let names = (try? WorktreeManager.list(repoPath: repoPath).map(\.name)) ?? []
            if names.contains(branch) {
                try WorktreeManager.remove(repoPath: repoPath, name: branch)
            }
            try WorktreeManager.deleteBranch(repoPath: repoPath, name: branch)
        } catch {
            return .failure(WorkspaceDeleteError(message: "delete failed: \(error)"))
        }
        removeWorkspace(id: workspaceID)   // drops from UI, releases port, discards views
        return .success(())
    }

    @discardableResult
    func controlDeleteWorkspace(id workspaceID: UUID) -> Result<Void, WorkspaceDeleteError> {
        pruneWorkspaceFromDisk(id: workspaceID)
    }

    /// Merge a linked workspace's branch into its recorded `baseBranch`, then
    /// prune it from disk exactly like `deleteWorkspace`. Refuses to touch
    /// anything unless BOTH the workspace being closed and the Space's
    /// primary workspace are clean — checked before the merge runs, since a
    /// headless merge advances the primary's branch ref without checking it
    /// out, which would make even a clean primary look dirty afterward if
    /// checked post-merge. A linked workspace's `baseBranch` is always the
    /// primary's branch in the app UI, but `casper workspace new --base
    /// <ref>` can fork a linked workspace from another linked workspace's
    /// branch instead — that stacked case is NOT covered here by design; a
    /// merge into a stacked, non-primary base is not blocked even if that
    /// base's worktree is dirty. If the merge can't be resolved
    /// automatically (conflicts, or the base branch no longer exists),
    /// returns `.mergeFailed` before touching anything — no disk cleanup, no
    /// UI removal. Never presents UI itself: the confirmation presenter owns
    /// showing any failure alert, which keeps this safe to call from tests
    /// without spawning a real `NSAlert`.
    @discardableResult
    func closeWorkspace(id workspaceID: UUID) -> WorkspaceCloseOutcome {
        guard let ws = workspace(id: workspaceID), ws.kind == .linked,
              let space = space(for: ws), space.isGitRepo,
              let baseBranch = ws.baseBranch, !baseBranch.isEmpty,
              let primary = space.workspaces.first(where: { $0.kind == .primary })
        else {
            return .mergeFailed(message: "workspace not found or has no base branch")
        }
        guard (try? WorktreeManager.isClean(repoPath: ws.worktreePath)) == true else {
            return .mergeFailed(
                message: "\u{201c}\(ws.name)\u{201d} has uncommitted changes. Commit or discard "
                    + "them before merging.")
        }
        guard (try? WorktreeManager.isClean(repoPath: primary.worktreePath)) == true else {
            return .mergeFailed(
                message: "\u{201c}\(primary.name)\u{201d} (branch \u{201c}\(baseBranch)\u{201d}) has "
                    + "uncommitted changes. Commit or discard them there before merging.")
        }
        do {
            _ = try WorktreeManager.merge(
                repoPath: space.folderPath, branch: ws.branch, into: baseBranch,
                message: "Merge branch '\(ws.branch)' into \(baseBranch)")
        } catch {
            CasperLog.app.failure("close workspace: merge failed", error)
            return .mergeFailed(
                message: "The merge into \u{201c}\(baseBranch)\u{201d} could not be completed "
                    + "automatically. Resolve it manually (e.g. in a terminal), then try again. "
                    + "Nothing was deleted.")
        }
        if case .failure(let error) = pruneWorkspaceFromDisk(id: workspaceID) {
            CasperLog.app.failure("close workspace: disk cleanup failed", error)
            return .cleanupFailed(
                message: "The merge succeeded, but the worktree or branch could not be removed "
                    + "from disk: \(error.message)")
        }
        // The primary is guaranteed clean at this point (checked above), so the
        // resync is unconditional: mergeBranchHeadless never runs git_checkout,
        // so without this the primary's `git status` would show the just-merged
        // files as `deleted:` until someone checks out manually.
        do {
            try WorktreeManager.resyncWorkingTree(repoPath: primary.worktreePath)
        } catch {
            CasperLog.app.failure("close workspace: primary worktree resync failed", error)
        }
        return .success
    }

    /// Delete a linked workspace from disk without merging: prune its worktree,
    /// delete its branch, then drop it from the UI. Never presents UI itself —
    /// see `closeWorkspace`.
    @discardableResult
    func deleteWorkspace(id workspaceID: UUID) -> Result<Void, WorkspaceDeleteError> {
        guard let ws = workspace(id: workspaceID), ws.kind == .linked else {
            return .failure(WorkspaceDeleteError(message: "workspace not found"))
        }
        return pruneWorkspaceFromDisk(id: workspaceID)
    }

    /// A confirmation, then `closeWorkspace(id:)` on confirm. No-op if the
    /// workspace has no recorded base branch (nothing to merge into) — the
    /// sidebar only offers this action in that case anyway. Per Apple HIG,
    /// the consequential "Merge and Close" button is never the Return-key
    /// default (compare Finder's "Empty Trash": Cancel stays the safe
    /// default, the destructive button just loses its Return binding).
    func presentCloseWorkspaceConfirmation(id workspaceID: UUID) {
        guard let ws = workspace(id: workspaceID), let baseBranch = ws.baseBranch, !baseBranch.isEmpty
        else { return }
        let alert = NSAlert()
        alert.messageText = "Merge and Close \u{201c}\(ws.name)\u{201d}?"
        alert.informativeText = "This merges branch \u{201c}\(ws.branch)\u{201d} into "
            + "\u{201c}\(baseBranch)\u{201d}, then deletes the worktree and its folder on disk. "
            + "This can\u{2019}t be undone."
        let mergeButton = alert.addButton(withTitle: "Merge and Close")
        alert.addButton(withTitle: "Cancel")
        mergeButton.hasDestructiveAction = true
        mergeButton.keyEquivalent = ""
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        switch closeWorkspace(id: workspaceID) {
        case .success:
            break
        case .mergeFailed(let message):
            presentWorkspaceOperationFailureAlert(
                title: "Could not close \u{201c}\(ws.name)\u{201d}", message: message)
        case .cleanupFailed(let message):
            presentWorkspaceOperationFailureAlert(
                title: "\u{201c}\(ws.name)\u{201d} merged but not fully cleaned up", message: message)
        }
    }

    /// A confirmation, then `deleteWorkspace(id:)` on confirm. Unlike
    /// `closeWorkspace`, this never merges, so uncommitted changes in `ws`
    /// really are discarded — the warning below stays. Same HIG-correct
    /// default-button treatment as `presentCloseWorkspaceConfirmation`.
    func presentDeleteWorkspaceConfirmation(id workspaceID: UUID) {
        guard let ws = workspace(id: workspaceID) else { return }
        let dirty = (try? WorktreeManager.isClean(repoPath: ws.worktreePath)) == false
        let alert = NSAlert()
        alert.messageText = "Delete \u{201c}\(ws.name)\u{201d}?"
        var text = "This deletes the worktree, its folder on disk, and branch "
            + "\u{201c}\(ws.branch)\u{201d} without merging. This can\u{2019}t be undone."
        if dirty { text += " This workspace has uncommitted changes that will be lost." }
        alert.informativeText = text
        let deleteButton = alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        deleteButton.hasDestructiveAction = true
        deleteButton.keyEquivalent = ""
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if case .failure(let error) = deleteWorkspace(id: workspaceID) {
            presentWorkspaceOperationFailureAlert(
                title: "Could not delete \u{201c}\(ws.name)\u{201d}", message: error.message)
        }
    }

    /// A generic error alert for a failed close/delete operation.
    private func presentWorkspaceOperationFailureAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
