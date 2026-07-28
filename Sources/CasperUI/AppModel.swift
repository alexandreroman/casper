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
/// synchronously; high-frequency edits (inspector width, surface font size)
/// debounce via `scheduleSave`.
@MainActor
@Observable
final class AppModel {
    private(set) var spaces: [Space] { didSet { refreshMenuFlags() } }
    var selectedWorkspaceID: UUID? { didSet { refreshMenuFlags() } }

    /// Observable revision token bumped when the selected workspace's folder
    /// changes on disk. The diff badge and diff surface re-pull on its change,
    /// giving them a live refresh without knowing about the filesystem watcher.
    private(set) var diffRevision = 0

    /// Observable revision token bumped when the selected workspace's
    /// `.casper.json` named commands change on disk (see
    /// `refreshNamedCommandsIfChanged`). The Run Script toolbar button re-reads
    /// its state on its change, giving it a live refresh without knowing about
    /// the filesystem watcher.
    private(set) var scriptsRevision = 0

    /// Editors detected as launchable at startup (CLI shim on `PATH` and app
    /// bundle resolvable), in `EditorKind.priorityOrder`. Never re-detected
    /// while the app is running.
    private(set) var availableEditors: [EditorKind] = []

    /// Set when `openInEditor` fails to launch; drives a `.alert` in
    /// `WorkspaceDetailView`. Not part of any persisted model.
    var editorLaunchError: String?

    /// Set when `runScript` fails to launch; drives a `.alert` in WorkspaceDetailView.
    var scriptRunError: String?

    /// Live progress of a workspace close/delete while its modal sheet is up; nil
    /// when no operation is visible. Publishing is deliberately lagged: the
    /// orchestrator tracks its own current step from the first instant, but only
    /// promotes it here once the operation has been running ~250 ms, so a close
    /// that finishes sooner never flashes a panel. Once non-nil it is written
    /// through on every step boundary, and back to nil when the operation ends —
    /// before any failure alert, so an `NSAlert` never stacks on a live sheet.
    var closeProgress: WorkspaceCloseProgress?

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

    /// Last window-visibility state `applyWatcherVisibility` acted on, so it can
    /// react only to real transitions. Starts `true` because `init` already armed
    /// the watchers as visible before any window seed arrives — matching that
    /// makes the first seed from a visible window a no-op.
    @ObservationIgnored private var lastAppliedWindowVisible = true

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
    /// Deliberately has NO `didSet { refreshMenuFlags() }`: no menu flag depends on
    /// the focused surface anymore (the always-enabled Split items enforce
    /// "terminal focused" in `applyNewSplit` itself), so a focus change must not
    /// re-assert the native menu — that resync is the menu-bar flicker we avoid.
    var focusedSurfaceID: UUID?

    // MARK: - Menu enable-state flags
    //
    // Edge-triggered mirrors of the menu enable-state computed properties. The
    // SwiftUI `.commands` menu body (`CasperCommands`) observes ONLY these flags —
    // never the raw `spaces` / `selectedWorkspaceID` inputs. If the body observed
    // those inputs directly, SwiftUI would re-assert the whole native menu on every
    // change, recreating the empty Format/Help stubs — a visible menu-bar flicker.
    // These flags change only when an enable-state actually flips, so the menu body
    // stays stable across `spaces` churn. `refreshMenuFlags()` keeps them in sync
    // from those two raw inputs' `didSet`, writing each flag only when its value
    // differs so an unchanged recompute never notifies observers. The Split items
    // are deliberately NOT backed by a flag: they are always enabled (see
    // `CasperCommands`), so nothing here observes `focusedSurfaceID`.
    private(set) var menuHasSelectedWorkspace = false
    private(set) var menuCanCreateWorkspace = false
    private(set) var menuCanDeleteSelectedWorkspace = false
    private(set) var menuCanCloseSelectedWorkspace = false

    /// A snapshot of EXACTLY the inputs the four menu enable-state flags read, used
    /// to skip the recompute when none of them could have changed. The flags depend
    /// only on selection and workspace membership/kind/Git-backing — never on
    /// `layout`/`agentState`/`todos`/`inspector` — yet `spaces.didSet` fires on
    /// every one of those high-frequency mutations (notably each agent-detection
    /// `agentState` flip). Comparing this fingerprint lets those churny mutations
    /// early-out of `refreshMenuFlags()`.
    ///
    /// Inputs captured (a deliberate superset of the four properties' reads —
    /// `hasSelectedWorkspace`, `canCreateWorkspace` via `targetSpaceForNewWorkspace`,
    /// `canDeleteSelectedWorkspace`, `canCloseSelectedWorkspace`): the selection,
    /// and per Space its `isGitRepo` plus each workspace's `id → kind`.
    /// `canCloseSelectedWorkspace` also reads the selected workspace's `baseBranch`,
    /// but a workspace's `baseBranch` is fixed at creation and never mutated after,
    /// so membership + kind already capture every way it can flip.
    private struct MenuFlagsFingerprint: Equatable {
        struct SpaceFingerprint: Equatable {
            let isGitRepo: Bool
            let workspaceKinds: [UUID: WorkspaceKind]
        }
        let selectedWorkspaceID: UUID?
        let spaces: [SpaceFingerprint]
    }

    /// Last fingerprint `refreshMenuFlags()` acted on. `nil` sentinel never equals a
    /// real fingerprint, so the first call (seeded at the end of `init`) always
    /// proceeds rather than being skipped.
    @ObservationIgnored private var lastMenuFlagsFingerprint: MenuFlagsFingerprint?

    /// Build the current menu-flags fingerprint in a single pass over `spaces`.
    private func menuFlagsFingerprint() -> MenuFlagsFingerprint {
        let spaceFingerprints = spaces.map { space in
            var kinds: [UUID: WorkspaceKind] = [:]
            for workspace in space.workspaces { kinds[workspace.id] = workspace.kind }
            return MenuFlagsFingerprint.SpaceFingerprint(
                isGitRepo: space.isGitRepo, workspaceKinds: kinds)
        }
        return MenuFlagsFingerprint(
            selectedWorkspaceID: selectedWorkspaceID, spaces: spaceFingerprints)
    }

    /// Recompute each menu flag from its computed property, writing only on a real
    /// change. The guarded write is essential: an unconditional write to an
    /// `@Observable` property notifies observers even when the value is unchanged,
    /// which would defeat the flicker fix.
    ///
    /// A fingerprint guard fronts the recompute: `spaces.didSet` fires on every
    /// `spaces` mutation (including the frequent agent-detection `agentState`
    /// flips), but the flags depend only on the inputs in `MenuFlagsFingerprint`.
    /// When the fingerprint is unchanged, none of the four flags can have changed,
    /// so return immediately and skip the four linear scans and their guarded
    /// writes. Correctness hinges on the fingerprint changing whenever any flag
    /// input changes (see `MenuFlagsFingerprint`), or a menu item could get stuck.
    private func refreshMenuFlags() {
        let fingerprint = menuFlagsFingerprint()
        guard fingerprint != lastMenuFlagsFingerprint else { return }
        lastMenuFlagsFingerprint = fingerprint

        if menuHasSelectedWorkspace != hasSelectedWorkspace { menuHasSelectedWorkspace = hasSelectedWorkspace }
        if menuCanCreateWorkspace != canCreateWorkspace { menuCanCreateWorkspace = canCreateWorkspace }
        if menuCanDeleteSelectedWorkspace != canDeleteSelectedWorkspace {
            menuCanDeleteSelectedWorkspace = canDeleteSelectedWorkspace
        }
        if menuCanCloseSelectedWorkspace != canCloseSelectedWorkspace {
            menuCanCloseSelectedWorkspace = canCloseSelectedWorkspace
        }
    }

    /// The surface currently being dragged by its grip, or nil. Set on drag begin/end.
    /// Only ever read internally (the `setDropHover` guard); no view observes it, so
    /// tracking it would needlessly invalidate views on every drag.
    @ObservationIgnored private var draggingSurfaceID: UUID?
    /// The pane currently under the drag and the zone the drop would use. One at a
    /// time; cleared whenever the drag ends so no highlight can get stuck.
    var dropHoverTarget: UUID?
    var dropHoverZone: LayoutTree.DropZone?

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

    /// Serial background queue for `persist()`'s atomic disk write. Encoding stays
    /// on the main actor (it needs the live state); only the blocking write is
    /// dispatched here so it never stalls the render/run loop. Serial + FIFO, so a
    /// later write never lands before an earlier one, and `flushPendingSave()` can
    /// drain it with a synchronous barrier for quit-safety and deterministic tests.
    @ObservationIgnored private let saveQueue = DispatchQueue(
        label: "com.github.alexandreroman.casper.session-save", qos: .utility)

    /// Whether the app's window is currently visible on screen — `false` when
    /// minimized, fully occluded by other windows, on another Space, or the app
    /// is hidden. Drives suspension of the terminal surfaces' render threads and
    /// the agent-detection cadence. Defaults `true` so a headless AppModel (no
    /// window, e.g. tests) never suspends work.
    var isWindowVisible = true

    /// Whether the app's window currently has key focus. Injectable for tests.
    @ObservationIgnored var isWindowKey: () -> Bool = { NSApp?.keyWindow != nil }

    /// Re-probe a folder path for Git backing. Injectable for tests.
    @ObservationIgnored var gitReprobe: (String) -> WorkspaceFactory.GitInfo? = {
        AppModel.gitProbePath($0)
    }

    /// Test hook fired after each successful/attempted persist. nil in production.
    @ObservationIgnored var onPersistForTest: (() -> Void)?

    /// Test-only: fired when `materializePendingSurfacesOffscreen` is asked to bring up a
    /// background workspace's pending surfaces, so headless tests (which have no runtime) can
    /// assert the background command path was triggered. Carries the workspace id.
    @ObservationIgnored var onMaterializePendingForTest: ((UUID) -> Void)?

    /// Fires for every step boundary regardless of the anti-flash delay, so tests can
    /// assert the step sequence without waiting 250 ms or instantiating a view.
    @ObservationIgnored var onCloseProgressForTest: ((WorkspaceCloseProgress) -> Void)?

    /// Delivers a local notification for a workspace. Injectable for tests; the
    /// default posts a best-effort `UserNotifications` request. Skipped entirely when
    /// the process has no bundle identifier (a bare `swift run` executable): on macOS
    /// 26 `UNUserNotificationCenter.current()` aborts rather than no-ops without a
    /// bundle, so guarding here keeps `make dev` runs from crashing on the first hook
    /// notification.
    ///
    /// The request identifier is the workspace id (not a random UUID) so the
    /// `AppDelegate`'s `didReceive` can route a tap back to the right workspace. It
    /// also means a second notification for the same workspace replaces the first in
    /// Notification Center instead of piling up — matching how
    /// `pendingNotificationMessage` only ever holds the latest message per workspace.
    @ObservationIgnored var deliverNotification:
        (String, String, UUID, UNNotificationInterruptionLevel) -> Void = { title, body, workspaceID, level in
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.interruptionLevel = level
        // A `.passive` notification is a silent addition to Notification Center (no
        // banner, no sound), so the system ignores any sound we set. Only attach a
        // sound for levels that actually surface it, rather than storing dead state.
        if level != .passive {
            content.sound = UNNotificationSound(named: UNNotificationSoundName("NotificationAlert.aiff"))
        }
        let request = UNNotificationRequest(
            identifier: workspaceID.uuidString, content: content, trigger: nil)
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

    /// Command to type into a terminal surface the first time its view is
    /// materialized (from `terminal new --command` / `workspace new --command`).
    /// Populated at creation (`controlOpenTerminal`, `createLinkedWorkspace`),
    /// consumed and removed on first `surfaceView(for:in:)` for that surface id
    /// — never replayed after. Never persisted: restoring `session.json` starts
    /// with an empty map, so a restored terminal never re-runs its original
    /// launch command (see the `surface-command-bash-exec` project memory note).
    @ObservationIgnored private var pendingInitialInput: [UUID: String] = [:]

    /// Off-screen host window that materializes a silently-created (control-channel)
    /// workspace's terminal surfaces — those carrying queued `pendingInitialInput` —
    /// so libghostty spawns their PTY and runs the queued command even though the
    /// workspace is never selected (its real view would otherwise never mount). When
    /// the user later selects the workspace, `SharedViewOwnership` reparents the
    /// cached `GhosttySurfaceView` from here into the visible container. Created lazily.
    @ObservationIgnored private var backgroundSurfaceNursery: NSWindow?

    /// Per-workspace named commands from `.casper.json`, refreshed on selection so
    /// SwiftUI never reads the file during `body`.
    @ObservationIgnored private var namedCommandsCache: [UUID: [RepoNamedCommand]] = [:]

    /// Workspaces with a close/delete operation in flight, claimed for the WHOLE
    /// operation rather than just its teardown wait. Stays on `AppModel` rather than
    /// moving to `ScriptHookRunner` for exactly that reason: it covers the cleanliness
    /// probes, the merge and the prune too, none of which is hook business.
    ///
    /// The claim has to be its own thing because the operation is now async: it awaits
    /// the cleanliness probes, the merge and the teardown hook, so a check made at entry
    /// says nothing by the time the work starts. Two callers are genuinely reachable —
    /// a window-modal sheet does not disable the menu bar, and `casper workspace delete`
    /// arrives over the control channel at any moment — and letting both through would
    /// strand the first one's continuation and run two libgit2 writers against the same
    /// repository. Claimed and released on the main actor with no `await` in between, so
    /// the check-and-insert is atomic. Transient, never persisted.
    @ObservationIgnored private var closingWorkspaces: Set<UUID> = []

    /// Per-workspace debounce/`done`-derivation state for the terminal-scraping
    /// agent detector. `AgentStateResolver` is a value type carried across ticks,
    /// so each workspace owns its own copy. Runtime-only; never persisted.
    @ObservationIgnored private var agentResolvers: [UUID: AgentStateResolver] = [:]

    /// Workspaces where `casper status set` took over: detection is suppressed
    /// for them and the explicit value is authoritative. Transient — an in-memory
    /// set, never persisted, so it naturally resets to "detection" on relaunch.
    @ObservationIgnored private var explicitAuthority: Set<UUID> = []

    /// When each workspace last delivered a macOS notification. Drives a short
    /// per-workspace de-dup cooldown (`notificationCooldown`) so a single real-world
    /// event can't produce two notifications when an explicit `casper notify` and a
    /// detection tick observe it near-simultaneously. Transient, never persisted.
    @ObservationIgnored var lastNotifiedAt: [UUID: Date] = [:]

    /// How long after a delivered notification a repeat for the same workspace is
    /// suppressed. Long enough to absorb the ~250ms detection tick racing an
    /// explicit `casper notify`, short enough not to swallow genuinely distinct events.
    static let notificationCooldown: TimeInterval = 3

    /// The repeating driver for `runAgentDetectionTick()`. GUI-only: started from
    /// the app lifecycle (`AppDelegate`), never from `init`, so unit tests that
    /// build an `AppModel` directly don't spin a background loop. Stored so it can
    /// be cancelled on teardown and so a second `startAgentDetection()` is a no-op.
    @ObservationIgnored private var agentDetectionTask: Task<Void, Never>?

    /// Rolling tick counter for `runAgentDetectionTick`, used to sub-sample the
    /// background (non-selected) workspaces. Bumped with `&+=` so it wraps rather
    /// than trapping on overflow.
    @ObservationIgnored private var detectionTickCount = 0

    /// Sub-cadence for scraping non-selected workspaces: the selected workspace
    /// stays at full cadence (~250ms) for a live sidebar/spinner, while background
    /// workspaces are scraped only every 4th tick (~1s while visible). They feed
    /// only the background `done` notification, which tolerates ~1s of extra
    /// latency (and the resolver debounces in ticks anyway), so the reduced rate
    /// trades imperceptible latency for a much cheaper hot path.
    nonisolated static let backgroundDetectionStride = 4

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
        self.availableEditors = EditorLauncher.detectInstalled()
        reconfigureWorktreeWatcher()
        // `didSet` does not fire during `init`, so seed the menu flags once now that
        // all three raw inputs are assigned.
        refreshMenuFlags()
    }

    deinit {
        worktreeWatcher?.stop()
        gitMetaWatcher?.stop()
        agentDetectionTask?.cancel()
    }

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

    /// Copy a workspace's worktree path to the general pasteboard. Backs the
    /// "Copy Workspace Path" items in the sidebar context menu and the Edit menu.
    func copyWorkspacePath(id: UUID) {
        guard let workspace = workspace(id: id) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(workspace.worktreePath, forType: .string)
    }

    /// Copy a workspace's branch name to the general pasteboard. Backs the
    /// "Copy Branch Name" items in the sidebar context menu and the Edit menu.
    func copyBranchName(id: UUID) {
        guard let workspace = workspace(id: id) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(workspace.branch, forType: .string)
    }

    /// Reveal a workspace's worktree folder in Finder. Backs the "Open in
    /// Finder" items in the sidebar context menu and the File menu.
    func openInFinder(id: UUID) {
        guard let workspace = workspace(id: id) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: workspace.worktreePath))
    }

    /// The Space a File-menu "Create Workspace" action targets: the selected
    /// workspace's Space when it is a Git repo, otherwise the first Git Space.
    /// nil when no Git Space exists (the menu item is then disabled).
    func targetSpaceForNewWorkspace() -> Space? {
        if let id = selectedWorkspaceID, let workspace = workspace(id: id),
           let space = space(for: workspace), space.isGitRepo {
            return space
        }
        return spaces.first(where: { $0.isGitRepo })
    }

    /// An index pair into `spaces` → `workspaces`, as resolved by `locate` /
    /// `locateSurface` / `indexPair`.
    typealias WorkspaceIndex = (space: Int, workspace: Int)

    /// Resolve the (space, workspace) index pair of the first workspace matching
    /// `predicate`, for in-place mutation.
    private func indexPair(where predicate: (Workspace) -> Bool) -> WorkspaceIndex? {
        for (si, space) in spaces.enumerated() {
            if let wi = space.workspaces.firstIndex(where: predicate) {
                return (si, wi)
            }
        }
        return nil
    }

    /// Resolve the (space, workspace) index pair for in-place mutation.
    private func locate(_ id: UUID) -> WorkspaceIndex? {
        indexPair { $0.id == id }
    }

    /// The workspace at a resolved index pair.
    private func workspace(at index: WorkspaceIndex) -> Workspace {
        spaces[index.space].workspaces[index.workspace]
    }

    /// Mutate the workspace at a resolved index pair **in place**. Going through
    /// `inout` (rather than a computed subscript's copy-in/copy-out) keeps the
    /// nested array subscripts' in-place access, so a hot-path write does not
    /// copy the whole `Workspace` in and back out — `spaces`' observable accessors
    /// still run, and `spaces.didSet` fires exactly once *per call*.
    ///
    /// "Per call" is load-bearing: grouping several field writes into one block
    /// deliberately collapses what used to be several `didSet` fires into one. That
    /// collapsing is only sound while none of the grouped fields is an input to
    /// `MenuFlagsFingerprint` (which captures only `selectedWorkspaceID`, each Space's
    /// `isGitRepo`, and each workspace's `id → kind`) — a future grouping that touches
    /// a fingerprint input must not be collapsed. The five sites that group writes
    /// today touch only `inspector.*` and `pendingNotification*`, none of which is a
    /// fingerprint input.
    private func updateWorkspace(at index: WorkspaceIndex, _ body: (inout Workspace) -> Void) {
        body(&spaces[index.space].workspaces[index.workspace])
    }

    /// Adopt `folderURL` into the session, keeping one Space per Git repository:
    ///
    /// - a folder that is a linked worktree of a repository already open joins that
    ///   repository's Space as a linked workspace — a worktree is part of its repo,
    ///   not a project of its own;
    /// - a folder that is a repository whose worktrees are already open as Spaces of
    ///   their own becomes their Space, reunifying them into it as linked workspaces;
    /// - any other folder becomes a Space, as before.
    ///
    /// A folder that is already tracked (as a Space or as one of its workspaces) is
    /// not added twice: it is just selected.
    func addSpace(folderURL: URL, probe: (URL) -> WorkspaceFactory.GitInfo?) {
        let folderPath = folderURL.path
        let candidate = Self.canonicalPath(folderPath)
        if let known = trackedWorkspaceID(atCanonicalPath: candidate) {
            CasperLog.app.error("folder already open: \(folderPath, privacy: .public)")
            selectWorkspace(known)
            return
        }
        let info = probe(folderURL)
        if let info, info.isLinkedWorktree,
           let spaceID = spaceSharingRepository(with: info, probe: probe) {
            adoptWorktree(at: folderURL, info: info, into: spaceID)
            return
        }
        let portBase: Int
        do {
            portBase = try portAllocator.allocate()
        } catch {
            CasperLog.app.failure("cannot add space: no free port block", error)
            return
        }
        var space = WorkspaceFactory.makeSpace(
            folderURL: folderURL, info: info, portBase: portBase)
        // The mirror image of adoption: this folder is the main working tree, so any
        // Space rooted at one of its worktrees is really a part of the Space being
        // created and is folded into it.
        let absorbed = info.map { worktreeSpaces(sharingRepositoryWith: $0, probe: probe) } ?? []
        reunify(absorbed, into: &space)
        // One write, so the absorbed workspaces are never momentarily absent from the
        // model: they keep running throughout, they only change Space.
        let absorbedIDs = Set(absorbed.map(\.id))
        var updated = spaces.filter { !absorbedIDs.contains($0.id) }
        updated.append(space)
        spaces = Self.sortedByName(updated)
        selectWorkspace(space.workspaces.first?.id)
        persist()
    }

    /// `path` with symlinks resolved, so two spellings of the same folder compare
    /// equal (on macOS `/tmp/x` and `/private/tmp/x` are the same directory).
    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// The id of the workspace Casper already tracks at `canonical`: either a Space
    /// rooted there (answering with its primary workspace) or any workspace whose
    /// worktree is that folder.
    private func trackedWorkspaceID(atCanonicalPath canonical: String) -> UUID? {
        for space in spaces {
            if Self.canonicalPath(space.folderPath) == canonical {
                return space.orderedWorkspaces.first?.id
            }
            if let match = space.workspaces.first(where: {
                Self.canonicalPath($0.worktreePath) == canonical
            }) {
                return match.id
            }
        }
        return nil
    }

    /// An open Space that turns out to be backed by the same Git repository as a
    /// folder being added, and which of the repository's working trees it roots at.
    private struct RepositoryMatch {
        let space: Space
        let isLinkedWorktree: Bool
    }

    /// Every open Space backed by the same Git repository as `info` — same common
    /// `.git` directory, which all of a repository's working trees share.
    private func spacesSharingRepository(
        with info: WorkspaceFactory.GitInfo, probe: (URL) -> WorkspaceFactory.GitInfo?
    ) -> [RepositoryMatch] {
        guard let commonDir = info.commonDirPath else { return [] }
        return spaces.compactMap { space in
            guard space.isGitRepo,
                  let spaceInfo = probe(URL(fileURLWithPath: space.folderPath)),
                  spaceInfo.commonDirPath == commonDir else { return nil }
            return RepositoryMatch(space: space, isLinkedWorktree: spaceInfo.isLinkedWorktree)
        }
    }

    /// The Space a worktree described by `info` should join, or nil when its
    /// repository isn't open. When both a repository's main working tree and one of
    /// its worktrees are open as Spaces, the main working tree wins: its folder is
    /// what worktree operations (create, prune, merge) run against.
    private func spaceSharingRepository(
        with info: WorkspaceFactory.GitInfo, probe: (URL) -> WorkspaceFactory.GitInfo?
    ) -> UUID? {
        let matches = spacesSharingRepository(with: info, probe: probe)
        return (matches.first(where: { !$0.isLinkedWorktree }) ?? matches.first)?.space.id
    }

    /// The open Spaces rooted at a worktree of `info`'s repository: what opening that
    /// repository's main working tree reunifies into a single Space. Spaces rooted at
    /// the main working tree itself are excluded — a Space always roots at the folder
    /// its primary workspace is, and `addSpace` has already ruled out a duplicate.
    private func worktreeSpaces(
        sharingRepositoryWith info: WorkspaceFactory.GitInfo,
        probe: (URL) -> WorkspaceFactory.GitInfo?
    ) -> [Space] {
        spacesSharingRepository(with: info, probe: probe)
            .filter(\.isLinkedWorktree)
            .map(\.space)
    }

    /// Move every workspace of `absorbed` into `space` as a linked workspace (see
    /// `linkedWorkspaces`), tearing down whatever cannot be carried over so a dropped
    /// workspace leaves behind neither a reserved port nor a cached view. The
    /// absorbed Spaces themselves are dropped by the caller, in the same write that
    /// installs `space`.
    private func reunify(_ absorbed: [Space], into space: inout Space) {
        guard !absorbed.isEmpty, let primary = space.workspaces.first else { return }
        space.workspaces.append(contentsOf: Self.linkedWorkspaces(
            absorbing: absorbed, baseBranch: primary.branch,
            excluding: Self.canonicalPath(primary.worktreePath)))
        let moved = Set(space.workspaces.map(\.id))
        for workspace in absorbed.flatMap(\.workspaces) where !moved.contains(workspace.id) {
            portAllocator.release(workspace.portBase)
            discardSurfaceViews(
                LayoutTree.surfaceIDs(workspace.layout) + [workspace.inspector.browser.id])
            pruneTransientState(for: workspace)
        }
    }

    /// The workspaces of `absorbed`, reshaped as linked workspaces of the Space that
    /// absorbs them. They move whole — same ids, ports, layouts and live terminals,
    /// so nothing is torn down or respawned — and only the fields that make a
    /// workspace linked are normalized: an absorbed Space's own worktree stops being
    /// a primary and takes its branch as its name (a Space is named after its
    /// repository, which would merely duplicate the new primary's name), and any
    /// workspace with no base branch of its own inherits `baseBranch`. A workspace
    /// that already records a base keeps it: that is the branch it forked from and
    /// still merges back into.
    ///
    /// A workspace rooted at `primaryPath` is dropped rather than moved: a second
    /// workspace on the absorbing Space's own working tree would be a linked
    /// workspace whose deletion removes the repository itself.
    private static func linkedWorkspaces(
        absorbing absorbed: [Space], baseBranch: String, excluding primaryPath: String
    ) -> [Workspace] {
        absorbed.flatMap(\.orderedWorkspaces)
            .filter { canonicalPath($0.worktreePath) != primaryPath }
            .map { workspace in
                var workspace = workspace
                if workspace.kind == .primary {
                    workspace.kind = .linked
                    if !workspace.branch.isEmpty { workspace.name = workspace.branch }
                }
                if workspace.baseBranch?.isEmpty ?? true { workspace.baseBranch = baseBranch }
                return workspace
            }
    }

    /// Add an existing worktree to `spaceID` as a linked workspace. Unlike
    /// `createLinkedWorkspace` nothing is created on disk — the branch and the
    /// worktree already exist, Casper merely starts tracking them — so the repo's
    /// `setup` hook does not run: it fires at creation only.
    @discardableResult
    private func adoptWorktree(
        at folderURL: URL, info: WorkspaceFactory.GitInfo, into spaceID: UUID
    ) -> Workspace? {
        guard let si = spaces.firstIndex(where: { $0.id == spaceID }) else { return nil }
        // Read before the selection moves below, exactly as `createLinkedWorkspace` does.
        let inheritedEditor = selectedWorkspaceID.flatMap { workspace(id: $0) }?.lastUsedEditor
        let portBase: Int
        do { portBase = try portAllocator.allocate() } catch {
            CasperLog.app.failure("cannot adopt worktree: no free port block", error)
            return nil
        }
        // Same shape as a Casper-created linked workspace: named after its branch,
        // with the Space's primary branch as the base it merges back into. A worktree
        // with no branch name of its own falls back to its folder name.
        let branch = info.branch
        let baseBranch = spaces[si].workspaces.first(where: { $0.kind == .primary })?.branch ?? ""
        var ws = WorkspaceFactory.makeLinkedWorkspace(
            name: branch.isEmpty ? folderURL.lastPathComponent : branch,
            worktreePath: info.canonicalPath, branch: branch,
            baseBranch: baseBranch, portBase: portBase)
        ws.lastUsedEditor = inheritedEditor
        spaces[si].workspaces.append(ws)
        selectWorkspace(ws.id)
        persist()
        return ws
    }

    /// The workspace selection should fall back to after a removal: the first
    /// remaining workspace of `space` in display order if it still has one,
    /// otherwise the first workspace of the first remaining Space overall.
    private func fallbackSelection(preferring space: Space?) -> UUID? {
        space?.orderedWorkspaces.first?.id ?? spaces.first?.orderedWorkspaces.first?.id
    }

    /// Prune every transient, non-persisted map keyed by a workspace being
    /// removed, so a long-lived session with workspace churn doesn't accumulate
    /// dead entries. Called from both `removeWorkspace` (linked drop) and
    /// `removeSpace` (whole-Space discard) so the two teardown paths can't drift.
    private func pruneTransientState(for ws: Workspace) {
        explicitAuthority.remove(ws.id)
        agentResolvers[ws.id] = nil
        namedCommandsCache[ws.id] = nil
        lastNotifiedAt[ws.id] = nil
        // The workspace's lifecycle-hook state: its teardown once-latch (resumed as it
        // is cleared — the workspace is being dropped outright here, so there is nothing
        // left for the destroy to prune) and the per-surface setup tags of a workspace
        // removed while its setup split is live.
        scriptHooks.forget(surfaceIDs: LayoutTree.surfaceIDs(ws.layout), workspaceID: ws.id)
    }

    func removeSpace(id: UUID) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        let removed = spaces.remove(at: index)
        for ws in removed.workspaces {
            portAllocator.release(ws.portBase)
            // The inspector browser lives outside the layout tree, so its coordinator
            // must be discarded explicitly alongside the terminal surfaces.
            discardSurfaceViews(LayoutTree.surfaceIDs(ws.layout) + [ws.inspector.browser.id])
            pruneTransientState(for: ws)
        }
        if let sel = selectedWorkspaceID, removed.workspaces.contains(where: { $0.id == sel }) {
            selectWorkspace(fallbackSelection(preferring: nil))
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
    /// primary workspace's branch (the prior behavior). `select` controls whether the
    /// new workspace becomes the selected/focused one; it defaults to true for UI
    /// creation and is set to false for the control-channel (CLI) path so a workspace
    /// created remotely does not steal the user's current selection. Returns the new
    /// workspace or a human-readable error.
    func createLinkedWorkspace(
        spaceID: UUID, name: String, base baseOverride: String?, command: String? = nil,
        select: Bool = true
    ) -> Result<Workspace, WorkspaceCreationError> {
        // Carry over the editor selected in the currently-active workspace (nil is
        // fine — it keeps the same resolved default). Captured before any selection
        // change so it reflects the workspace active when creation was requested.
        let inheritedEditor = selectedWorkspaceID.flatMap { workspace(id: $0) }?.lastUsedEditor
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
            return .failure(WorkspaceCreationError(message: error.localizedDescription))
        }
        var ws = WorkspaceFactory.makeLinkedWorkspace(
            name: branch, worktreePath: worktreePath, branch: branch,
            baseBranch: base, portBase: portBase)
        ws.lastUsedEditor = inheritedEditor
        if let command, let terminalID = LayoutTree.surfaceIDs(ws.layout).first {
            pendingInitialInput[terminalID] = command
        }
        spaces[si].workspaces.append(ws)
        // Only steal focus for UI-initiated creation. A workspace created from the
        // CLI (control channel) is added silently, without changing the user's
        // current selection.
        if select {
            selectWorkspace(ws.id)
        }
        persist()
        // Run the repo's `setup` lifecycle hook (if any) in a visible split, once,
        // at creation only — never on restore/re-open (this call site is the guard,
        // so no persisted "setup ran" flag is needed). A malformed .casper.json
        // already failed creation in WorktreeManager.create above (Part A); this
        // re-read's `try?`/nil therefore just means "no setup script".
        if let setup = (try? RepoConfig.load(fromRepoRoot: worktreePath))??.setupScript() {
            scriptHooks.runSetupHook(in: ws.id, command: setup)
        }
        // A silently-created (control-channel) workspace is never selected, so its views
        // never mount on their own. Bring the surface carrying the queued `command` up
        // off-screen so it runs now, in the background, instead of waiting for the user to
        // select the workspace. (UI creation takes the `select` path above and mounts its
        // views normally, so this is scoped to the silent path.) The `setup` split just
        // above is NOT covered here: `insertHookSurface` materializes every hook split
        // itself, so each site brings up exactly the surfaces whose input it queued.
        if !select, command != nil, let created = workspace(id: ws.id) {
            materializePendingSurfacesOffscreen(in: created)
        }
        return .success(ws)
    }

    /// Drop a linked workspace (never a primary); releases its port, leaves the
    /// worktree and branch on disk.
    func removeWorkspace(id: UUID) {
        guard let at = locate(id) else { return }
        guard workspace(at: at).kind == .linked else { return }
        let ws = spaces[at.space].workspaces.remove(at: at.workspace)
        portAllocator.release(ws.portBase)
        // The inspector browser lives outside the layout tree, so its coordinator
        // must be discarded explicitly alongside the terminal surfaces.
        discardSurfaceViews(LayoutTree.surfaceIDs(ws.layout) + [ws.inspector.browser.id])
        // Prune the transient maps so they don't grow unbounded across a long session
        // (both the close and control-destroy paths funnel through here).
        pruneTransientState(for: ws)
        if selectedWorkspaceID == id {
            selectWorkspace(fallbackSelection(preferring: spaces[at.space]))
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
        refreshNamedCommands(for: id)
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
        // A `done` workspace is "finished, not yet seen"; selecting it is
        // exactly the "seen" event, so collapse it back to `idle` here —
        // mirroring the resolver's own seen-gated unlatch
        // (`AgentStateResolver`), but for the explicit-authority path the
        // resolver never runs for (see
        // `.superpowers/themes/agent-state-detection.md` § Authority). Not
        // gated on `isWindowKey()`, unlike the bubble clear above: the
        // resolver's own "seen" test is selection alone. `blocked`/`error`
        // are untouched — selection has no power over them.
        if let at = locate(id), workspace(at: at).agentState == .done {
            updateWorkspace(at: at) { $0.agentState = .idle }
        }
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

    /// Stop both selected-worktree watchers without rebuilding them.
    private func stopWorktreeWatchers() {
        worktreeWatcher?.stop()
        worktreeWatcher = nil
        gitMetaWatcher?.stop()
        gitMetaWatcher = nil
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
        // Never leave watchers armed while the window is hidden: the visibility
        // path (`applyWatcherVisibility`) is the only thing that starts them.
        guard isWindowVisible else { stopWorktreeWatchers(); return }
        stopWorktreeWatchers()
        guard let id = selectedWorkspaceID, let at = locate(id) else { return }
        let ws = workspace(at: at)
        let path = ws.worktreePath
        // Open the repo once (when the Space is a Git repo) and reuse the same handle
        // for both the ignored-directory exclusions and the reflog watcher below.
        let repo = spaces[at.space].isGitRepo ? try? Repository.open(atPath: path) : nil
        var exclusions: [String] = []
        if spaces[at.space].isGitRepo {
            exclusions.append(path + "/.git")
            if let repo {
                exclusions.append(contentsOf: (try? repo.ignoredTopLevelDirectories()) ?? [])
            }
        }
        // FSEventStreamSetExclusionPaths accepts at most 8 paths; .git stays first.
        if exclusions.count > 8 { exclusions = Array(exclusions.prefix(8)) }
        worktreeWatcher = makeWorktreeWatcher(path, exclusions, makeWorktreeChangeHandler())
        // Commit detection: watch the resolved gitdir's reflog directory, which the
        // `.git`-excluded worktree watcher above can't see. `gitDirPath` carries a
        // trailing slash and, for a linked worktree, resolves to
        // `<maindir>/.git/worktrees/<name>/`, so its `logs/HEAD` reflog is the one
        // that moves on this worktree's commits. Reuse `makeWorktreeWatcher` (the
        // test injection seam) with no exclusions, routing through the same debounced
        // hop as the primary watcher. Degrades gracefully to nil if the repo can't be
        // opened or the logs dir can't be watched.
        if let repo {
            let logsPath = repo.gitDirPath + "logs"
            gitMetaWatcher = makeWorktreeWatcher(logsPath, [], makeWorktreeChangeHandler())
        }
    }

    /// Suspend or resume the selected-worktree FSEvents watchers with window
    /// visibility. Hidden ⇒ stop them (a busy background worktree must not wake
    /// the main actor for a window nobody sees). Visible ⇒ re-arm and bump
    /// `diffRevision` once so the diff/summary catches up on anything missed
    /// while hidden.
    func applyWatcherVisibility() {
        // Act only on an actual visibility transition. The initial `true` matches
        // `init`, which already armed the watchers as visible — so the first seed
        // from a visible window is a no-op (no redundant re-arm or diff bump), and
        // repeated same-state occlusion notifications do nothing.
        guard lastAppliedWindowVisible != isWindowVisible else { return }
        lastAppliedWindowVisible = isWindowVisible
        if isWindowVisible {
            reconfigureWorktreeWatcher()
            diffRevision += 1
        } else {
            stopWorktreeWatchers()
        }
    }

    /// The debounced watcher callback shared by both worktree watchers: hop to the
    /// main actor and, after the debounce window, drive `handleSelectedWorktreeChange`.
    private func makeWorktreeChangeHandler() -> @Sendable () -> Void {
        { [weak self] in
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
        refreshNamedCommandsIfChanged(for: id)
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
            // Resolve the primary by kind, not position; skip the branch write if none.
            if let pi = spaces[si].workspaces.firstIndex(where: { $0.kind == .primary }) {
                spaces[si].workspaces[pi].branch = info.branch
            }
        }
    }

    /// Re-probe a not-yet-Git space and, if it now has a repository, promote it:
    /// mark it Git-backed, adopt HEAD's branch on its primary workspace, and
    /// persist. Returns whether a promotion happened. Reuses the injectable
    /// `gitReprobe`. (Formerly driven by the heartbeat poll.)
    @discardableResult
    func promoteSpaceIfGitInitialized(spaceIndex si: Int) -> Bool {
        // Resolve the primary by kind, not position; a missing primary fails safe (no promotion).
        guard spaces.indices.contains(si), !spaces[si].isGitRepo,
              let info = gitReprobe(spaces[si].folderPath),
              let pi = spaces[si].workspaces.firstIndex(where: { $0.kind == .primary }) else { return false }
        spaces[si].isGitRepo = true
        spaces[si].workspaces[pi].branch = info.branch
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
        // Resolve the primary by kind, not position; a missing primary fails safe (no demotion).
        guard spaces.indices.contains(si), spaces[si].isGitRepo,
              gitReprobe(spaces[si].folderPath) == nil,
              let pi = spaces[si].workspaces.firstIndex(where: { $0.kind == .primary }) else { return false }
        spaces[si].isGitRepo = false
        spaces[si].workspaces[pi].branch = ""   // degenerate primaries carry an empty branch
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
    /// keeps a freshly mounted background surface from stealing focus — and, since
    /// libghostty gives a brand-new surface no defined initial focus state, every
    /// non-focused pane needs an explicit blur to render correctly, not just an
    /// early return, or it would keep libghostty's default (solid-caret) state.
    private func focusSurfaceViewIfActive(_ id: UUID) {
        guard id == focusedSurfaceID else {
            (surfaceViews[id] as? GhosttySurfaceView)?.blurForLayoutChange()
            return
        }
        focusActiveSurfaceView()
    }

    /// The (space, workspace) index pair whose layout contains `surfaceID`.
    private func locateSurface(_ surfaceID: UUID) -> WorkspaceIndex? {
        indexPair { LayoutTree.surfaceIDs($0.layout).contains(surfaceID) }
    }

    /// Whether `focusedSurfaceID` currently points at a TERMINAL pane in some
    /// workspace's layout tree. Non-layout surfaces (the Inspector browser), layout
    /// browser/diff surfaces, and "nothing focused" all return false. Gates
    /// `applyNewSplit` — Split only makes sense on a focused terminal.
    func focusedSurfaceIsTerminal() -> Bool {
        guard let id = focusedSurfaceID else { return false }
        for space in spaces {
            for ws in space.workspaces {
                if let surface = LayoutTree.surfaces(ws.layout).first(where: { $0.id == id }) {
                    if case .terminal = surface.kind { return true }
                    return false
                }
            }
        }
        return false
    }

    /// Shared tail of every split-based surface addition: split the leaf holding
    /// `focused` in workspace `at` to insert `surface` along `orientation`/`side`,
    /// then persist. When the split targets the currently-visible workspace it also
    /// moves focus to the new surface and re-anchors the AppKit first responder;
    /// when it targets a background workspace (e.g. `casper terminal new
    /// --workspace <other>`) the layout still changes but focus is left untouched.
    /// Callers resolve their own target and surface, then delegate here.
    private func insertSurfaceBySplitting(
        at: WorkspaceIndex, focused: UUID,
        orientation: LayoutNode.Orientation, side: LayoutTree.InsertSide, surface: Surface
    ) {
        // A split into a background workspace must not disturb the visible terminal:
        // reassigning focus (or blurring) here would hollow the caret of the pane the
        // user is actually typing into and strand `focusedSurfaceID` on an off-screen
        // surface. `selectWorkspace` assigns focus to the new workspace's top-left
        // surface when the user switches to it, so no focus state is lost by skipping.
        let targetsVisibleWorkspace = workspace(at: at).id == selectedWorkspaceID
        if targetsVisibleWorkspace, let currentlyFocused = focusedSurfaceID {
            // Blur the surface that actually currently holds focus before the layout
            // restructure. Note this is `focusedSurfaceID`, NOT the `focused` split
            // anchor — a context-menu split can target a pane other than the focused
            // one. The SwiftUI re-render this triggers can silently detach the focused
            // view from the window (reparenting an ancestor container) before AppKit
            // fires `resignFirstResponder`, so libghostty would otherwise keep
            // rendering a solid caret on it even though the new surface holds focus.
            (surfaceViews[currentlyFocused] as? GhosttySurfaceView)?.blurForLayoutChange()
        }
        let (layout, newFocus) = LayoutTree.split(
            workspace(at: at).layout,
            focused: focused, orientation: orientation, side: side, surface: surface)
        updateWorkspace(at: at) { $0.layout = layout }
        persist()
        if targetsVisibleWorkspace {
            focusedSurfaceID = newFocus
            focusActiveSurfaceView()
        }
    }

    /// Add a new terminal by splitting the anchored surface (or the focused one
    /// when `anchor` is nil) to the RIGHT.
    func applyNewTerminal(anchor: UUID? = nil) {
        guard let target = anchor ?? focusedSurfaceID, let at = locateSurface(target) else { return }
        let cwd = workspace(at: at).worktreePath
        insertSurfaceBySplitting(
            at: at, focused: target, orientation: .horizontal, side: .after,
            surface: Surface.terminal(cwd: cwd))
    }

    /// Split the given surface with a new terminal in `direction` (the pane
    /// context-menu action; always creates a terminal).
    func applySplit(from surfaceID: UUID, direction: GhosttySplitDirectionLike) {
        guard let at = locateSurface(surfaceID) else { return }
        let cwd = workspace(at: at).worktreePath
        let (orientation, side) = LayoutTree.orientationAndSide(for: direction)
        insertSurfaceBySplitting(
            at: at, focused: surfaceID, orientation: orientation, side: side,
            surface: Surface.terminal(cwd: cwd))
    }

    /// Split the focused terminal in `direction` (the View menu's Split items). Those
    /// items are always enabled in the menu — never greyed — so the action itself is
    /// the gate: it does nothing unless a terminal is focused.
    func applyNewSplit(_ direction: GhosttySplitDirectionLike) {
        guard focusedSurfaceIsTerminal() else { return }
        guard let focus = focusedSurfaceID, let at = locateSurface(focus) else { return }
        let cwd = workspace(at: at).worktreePath
        let (orientation, side) = LayoutTree.orientationAndSide(for: direction)
        insertSurfaceBySplitting(
            at: at, focused: focus, orientation: orientation, side: side,
            surface: Surface.terminal(cwd: cwd))
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
        // Both setup guards below correlate a surface's child-exit with the
        // close_surface_cb libghostty delivers for it afterward — the same assumption
        // every shell-exit-driven pane close relies on (true for the current pin). If a
        // future pin suppressed that close, a successful setup's split would linger, and
        // the failure marker would instead swallow the user's first manual close.
        // A setup surface whose exit hasn't been processed yet is never torn down by
        // an early/stray close — its fate is decided by handleScriptSurfaceExit.
        if scriptHooks.isPendingSetupSurface(surfaceID) { return }
        // Swallow the one shell-exit-driven close that follows a FAILED setup so the
        // pane (with its error output) survives; a later user close then proceeds
        // normally (marker consumed, tag gone).
        if scriptHooks.consumeKeptFailedSetup(surfaceID) { return }
        // A teardown split still carrying its tag is being closed before its
        // child-exit was processed — i.e. the user closed it manually. Finish the
        // pending teardown now instead of waiting out the 30s timeout, then let the
        // caller's prune tear the whole workspace (including this split) down. In the
        // normal flow the tag is already cleared by handleScriptSurfaceExit before this
        // close arrives, so this branch is skipped. See the runner for why the resume
        // goes through the split's own `onExit`.
        if scriptHooks.finishManuallyClosedTeardown(surfaceID) { return }
        guard let at = locateSurface(surfaceID) else { return }
        let wasFocused = focusedSurfaceID == surfaceID
        let (layout, newFocus) = LayoutTree.closeSurface(
            workspace(at: at).layout, surface: surfaceID)
        if let layout {
            updateWorkspace(at: at) { $0.layout = layout }
            if wasFocused { focusedSurfaceID = newFocus }
            discardSurfaceViews([surfaceID])
            persist()
            focusActiveSurfaceView()
            return
        }
        // Last surface in the workspace was closed. Discard its views, then close
        // the workspace non-destructively — never taking down anything that depends
        // on it (its worktree/branch, or a Space's linked workspaces).
        let ws = workspace(at: at)
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
            let fresh = Surface.terminal(cwd: ws.worktreePath)
            updateWorkspace(at: at) { $0.layout = .leaf(fresh) }
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
            workspace(at: at).layout,
            surfaceID: surfaceID, toTarget: targetID, direction: zone.direction)
        else { return }
        updateWorkspace(at: at) { $0.layout = layout }
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
        var configuration = surfaceConfiguration(for: workspace, terminal: surface)
        if let command = pendingInitialInput.removeValue(forKey: surface.id) {
            configuration.initialInput = command + "\n"
        }
        let view = GhosttySurfaceView(
            runtime: runtime,
            configuration: configuration,
            surfaceID: surface.id,
            onFocus: { [weak self] id in self?.focusSurface(id) },
            onAttach: { [weak self] id in self?.focusSurfaceViewIfActive(id) },
            onClose: { [weak self] id in self?.applyCloseSurface(id) },
            onContextMenu: { [weak self, id = surface.id] _ in self?.paneContextMenu(for: id) },
            onFontSizeChange: { [weak self] id, size in self?.updateSurfaceFontSize(id, size: size) },
            onChildExit: { [weak self] id, code in self?.handleScriptSurfaceExit(id, code: code) })
        surfaceViews[surface.id] = view
        return view
    }

    /// Eagerly bring up — parked off-screen — every terminal surface in `workspace`
    /// that has queued initial input, so its command (a `--command`, or a `setup`
    /// hook) runs in the background without stealing the user's current selection.
    /// Used only for control-channel (silent) creation; UI creation selects the
    /// workspace, which mounts its views the normal way. No-op until the runtime exists.
    private func materializePendingSurfacesOffscreen(in workspace: Workspace) {
        onMaterializePendingForTest?(workspace.id)
        guard runtime != nil else { return }
        let pending = LayoutTree.surfaces(workspace.layout).filter { pendingInitialInput[$0.id] != nil }
        guard !pending.isEmpty else { return }
        let nursery = backgroundSurfaceNursery ?? makeBackgroundSurfaceNursery()
        guard let host = nursery.contentView else { return }
        for surface in pending {
            // surfaceView(for:) drains pendingInitialInput into the configuration and
            // caches the view; hosting it in a window drives viewDidMoveToWindow ->
            // createSurfaceIfNeeded -> PTY spawn -> the queued command.
            guard let view = surfaceView(for: surface, in: workspace), view.window == nil else { continue }
            view.frame = host.bounds
            view.autoresizingMask = [.width, .height]
            host.addSubview(view)
        }
    }

    /// Borderless window parked far off-screen (mirrors `BrowserCapture`), sized so
    /// hosted surfaces get valid dimensions. Borderless windows never become key, so
    /// this never steals keyboard focus; parked off any display its surfaces read as
    /// occluded and libghostty pauses their render thread (the PTY still runs).
    private func makeBackgroundSurfaceNursery() -> NSWindow {
        let frame = NSRect(x: -100_000, y: -100_000, width: 800, height: 600)
        let window = NSWindow(
            contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = NSView(frame: NSRect(origin: .zero, size: frame.size))
        window.orderFrontRegardless()
        backgroundSurfaceNursery = window
        return window
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

    /// The Git diff read/cache layer (`computeDiff`, `diffSummary` and the two
    /// file-text readers feeding the diff surface's highlighting). Lazy so the
    /// injected closure can capture a fully-initialized `self`; it captures it WEAKLY,
    /// because this model owns the service and a strong capture would close the retain
    /// cycle. The `?? 0` fallback only ever applies once this model is gone, at which
    /// point no view is left to observe the diff. `diffRevision` stays here: it is
    /// `@Observable` state the diff views watch directly.
    @ObservationIgnored private(set) lazy var diffService = DiffService(
        currentRevision: { [weak self] in self?.diffRevision ?? 0 })

    /// Rewrite a browser surface's persisted URL (address-bar navigation).
    /// Browsers live exclusively in each workspace's inspector, so this matches the
    /// surface against the inspector browsers alone — there is no layout-tree search.
    ///
    /// `syncNav` fires on both `didCommit` and `didFinish`, so persistence is
    /// debounced via `scheduleSave()` and skipped entirely when the committed URL
    /// already matches the stored one — a page load must not thrash the session file.
    func setBrowserURL(_ surfaceID: UUID, _ url: URL) {
        if let at = indexPair(where: { $0.inspector.browser.id == surfaceID }) {
            if case .browser(let current) = workspace(at: at).inspector.browser.kind,
               current == url { return }
            updateWorkspace(at: at) {
                $0.inspector.browser = Surface(id: surfaceID, kind: .browser(url: url))
            }
            scheduleSave()
        }
    }

    /// Flip the inspector panel's collapsed state for a workspace (toolbar toggle).
    func toggleInspectorCollapsed(for workspaceID: UUID) {
        guard let at = locate(workspaceID) else { return }
        updateWorkspace(at: at) { $0.inspector.collapsed.toggle() }
        persist()
    }

    /// Select the inspector's active tab, expanding the panel if it was collapsed.
    func setInspectorTab(_ tab: InspectorTab, for workspaceID: UUID) {
        guard let at = locate(workspaceID) else { return }
        updateWorkspace(at: at) {
            $0.inspector.tab = tab
            $0.inspector.collapsed = false
        }
        persist()
    }

    /// Toggle behavior for a title-bar tab button: expand onto `tab` if the
    /// panel is collapsed, collapse if it's already open on `tab`, otherwise
    /// switch to `tab` while keeping the panel open.
    func toggleInspectorTab(_ tab: InspectorTab, for workspaceID: UUID) {
        guard let at = locate(workspaceID) else { return }
        let inspector = workspace(at: at).inspector
        if inspector.collapsed {
            updateWorkspace(at: at) {
                $0.inspector.collapsed = false
                $0.inspector.tab = tab
            }
        } else if inspector.tab == tab {
            updateWorkspace(at: at) { $0.inspector.collapsed = true }
        } else {
            updateWorkspace(at: at) { $0.inspector.tab = tab }
        }
        persist()
    }

    /// Explicitly set the inspector's collapsed state (the panel's collapse button).
    func setInspectorCollapsed(_ collapsed: Bool, for workspaceID: UUID) {
        guard let at = locate(workspaceID) else { return }
        updateWorkspace(at: at) { $0.inspector.collapsed = collapsed }
        persist()
    }

    /// Resolves which editor a click should launch: an explicit `kind` (from
    /// picking a dropdown row) wins, else the workspace's remembered default,
    /// else the first detected editor. Pure and side-effect-free so it is
    /// unit-testable without touching `EditorLauncher`/`Process`.
    func resolvedEditor(_ kind: EditorKind?, for workspace: Workspace) -> EditorKind? {
        let remembered = workspace.lastUsedEditor.flatMap { availableEditors.contains($0) ? $0 : nil }
        return kind ?? remembered ?? availableEditors.first
    }

    /// Launches `kind` (or the workspace's remembered/default editor when
    /// nil) on the workspace's worktree, and remembers it as this
    /// workspace's default for next time.
    func openInEditor(_ kind: EditorKind?, for workspaceID: UUID) {
        guard let at = locate(workspaceID) else { return }
        let workspace = self.workspace(at: at)
        guard let resolved = resolvedEditor(kind, for: workspace) else { return }
        do {
            try EditorLauncher.launch(resolved, at: workspace.worktreePath)
            editorLaunchError = nil
            updateWorkspace(at: at) { $0.lastUsedEditor = resolved }
            persist()
        } catch {
            editorLaunchError = error.localizedDescription
        }
    }

    /// Changes the workspace's remembered default editor without launching it —
    /// used by the dropdown's picker rows, which only set the selection; only the
    /// split-button's primary action (`openInEditor`) actually launches.
    func selectEditor(_ kind: EditorKind, for workspaceID: UUID) {
        guard let at = locate(workspaceID) else { return }
        updateWorkspace(at: at) { $0.lastUsedEditor = kind }
        persist()
    }

    /// The workspace's named commands (`.casper.json`, non-reserved, sorted).
    /// Cached; a cache miss loads and stores lazily.
    func namedCommands(for workspaceID: UUID) -> [RepoNamedCommand] {
        if let cached = namedCommandsCache[workspaceID] { return cached }
        let commands = loadNamedCommands(for: workspaceID)
        namedCommandsCache[workspaceID] = commands
        return commands
    }

    private func loadNamedCommands(for workspaceID: UUID) -> [RepoNamedCommand] {
        guard let ws = workspace(id: workspaceID),
              let config = (try? RepoConfig.load(fromRepoRoot: ws.worktreePath)) ?? nil
        else { return [] }
        return config.namedCommands()
    }

    /// Re-read a workspace's named commands (e.g. after it becomes selected).
    private func refreshNamedCommands(for workspaceID: UUID) {
        namedCommandsCache[workspaceID] = loadNamedCommands(for: workspaceID)
    }

    /// Re-read a workspace's named commands from `.casper.json` in reaction to a
    /// filesystem change, updating the cache and bumping `scriptsRevision` only
    /// when the list actually changed. Idempotent on an unchanged file: the
    /// watcher has no `IgnoreSelf`, so Casper's own writes into the worktree also
    /// wake it, and an unchanged file must not churn the UI. A broken or missing
    /// file yields an empty list (same tolerance as `loadNamedCommands`).
    func refreshNamedCommandsIfChanged(for workspaceID: UUID) {
        let fresh = loadNamedCommands(for: workspaceID)
        guard fresh != namedCommandsCache[workspaceID] else { return }
        namedCommandsCache[workspaceID] = fresh
        scriptsRevision += 1
    }

    /// The command the toolbar's primary button runs: the remembered last-used
    /// command if still defined, else `run`, else the first alphabetically.
    func resolvedScript(for workspace: Workspace) -> RepoNamedCommand? {
        let commands = namedCommands(for: workspace.id)
        if let last = workspace.lastUsedScript,
           let match = commands.first(where: { $0.name == last }) {
            return match
        }
        if let run = commands.first(where: { $0.name == "run" }) { return run }
        return commands.first
    }

    /// Remember a workspace's script without running it — the toolbar menu's
    /// action (mirrors `selectEditor`); the primary button runs the remembered one.
    func selectScript(_ name: String, for workspaceID: UUID) {
        guard let at = locate(workspaceID) else { return }
        updateWorkspace(at: at) { $0.lastUsedScript = name }
        persist()
    }

    /// Run a named command in a visible terminal and remember it. On failure,
    /// sets `scriptRunError` (surfaced by an alert).
    func runScript(_ name: String, for workspaceID: UUID) {
        switch controlRun(name: name, in: workspaceID) {
        case .success:
            if let at = locate(workspaceID) {
                updateWorkspace(at: at) { $0.lastUsedScript = name }
            }
            scriptRunError = nil
            persist()
        case .failure(let error):
            scriptRunError = error.message
        }
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
        guard clamped.rounded() != workspace(at: at).inspector.width.rounded()
        else { return }
        updateWorkspace(at: at) { $0.inspector.width = clamped }
        scheduleSave()
    }

    /// Persist a split's divider positions for the given workspace after the user
    /// drags a divider or double-clicks to equalize. `path` is the child-index path
    /// from that workspace's root layout to the target `.split` node (`[]` is the
    /// root). Defensively re-normalizes `ratios` to sum to 1 (no-op on a
    /// non-positive sum), applies `LayoutTree.updateRatios`, and schedules the
    /// debounced save — mirroring `setInspectorWidth`'s drag-persistence pattern.
    /// No-op when the workspace or path is stale/invalid or nothing changed.
    func setSplitRatios(at path: [Int], ratios: [Double], for workspaceID: UUID) {
        guard let at = locate(workspaceID) else { return }
        let sum = ratios.reduce(0, +)
        guard sum > 0 else { return }
        let normalized = ratios.map { $0 / sum }
        let current = workspace(at: at).layout
        let updated = LayoutTree.updateRatios(in: current, at: path, ratios: normalized)
        guard updated != current else { return }
        updateWorkspace(at: at) { $0.layout = updated }
        scheduleSave()
    }

    /// Record a terminal surface's live font size (reported after a
    /// Cmd+/Cmd-/Cmd0 change forwarded to libghostty) into its persisted
    /// `Surface`, and schedule the existing debounced save — mirrors
    /// `setInspectorWidth`'s drag-persistence pattern.
    func updateSurfaceFontSize(_ surfaceID: UUID, size: Float) {
        guard let at = locateSurface(surfaceID) else { return }
        let updated = LayoutTree.updateSurface(
            workspace(at: at).layout, id: surfaceID
        ) { $0.fontSize = size }
        updateWorkspace(at: at) { $0.layout = updated }
        scheduleSave()
    }

    /// Drop cached views and browser coordinators for the given surface ids
    /// (their PTYs or `WKWebView`s are freed on deinit).
    private func discardSurfaceViews(_ ids: [UUID]) {
        for id in ids {
            // A background-nursery-hosted view is retained by the nursery's content view;
            // detach it so niling the cache actually frees the PTY. (A view that was later
            // selected lives in a real container and is torn down by SwiftUI.)
            if let nursery = backgroundSurfaceNursery, let view = surfaceViews[id], view.window === nursery {
                view.removeFromSuperview()
            }
            surfaceViews[id] = nil
            browserCoordinators[id] = nil
            pendingInitialInput[id] = nil
        }
    }

    /// Encode the session on the main actor (where the state lives), then hand the
    /// resulting `Data` to `saveQueue` for the blocking atomic disk write — keeping
    /// the write off the render/run loop. Only `sessionStore` and `data` (both
    /// `Sendable`) are captured; never `self`/`spaces`. `onPersistForTest?()` fires
    /// synchronously right after enqueuing (not after the write completes), so the
    /// save-count tests, which count `persist()` calls rather than disk writes, are
    /// unaffected — and it still fires even when the encode throws.
    func persist() {
        do {
            let data = try sessionStore.encode(
                Session(spaces: spaces, selectedWorkspaceID: selectedWorkspaceID))
            saveQueue.async { [sessionStore] in
                do {
                    try sessionStore.write(data)
                } catch {
                    CasperLog.app.failure("failed to persist session", error)
                }
            }
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
        // Drain the serial save queue so the just-enqueued write (and any prior
        // ones) have hit disk before returning. This preserves
        // `applicationWillTerminate`'s guarantee that state is persisted before the
        // app exits, and makes the tests' post-mutation `store.load()` deterministic.
        saveQueue.sync {}
    }

    /// The per-surface environment injected into a terminal so the `casper` CLI
    /// resolves and the agent sees its reserved ports.
    func surfaceConfiguration(
        for workspace: Workspace, terminal: Surface
    ) -> GhosttySurfaceConfiguration {
        guard case .terminal(let cwd) = terminal.kind else {
            return GhosttySurfaceConfiguration()
        }
        var config = GhosttySurfaceConfiguration(
            workingDirectory: cwd, fontSize: terminal.fontSize ?? 0)
        config.environment = ClaudeCodeAdapter.surfaceEnvironment(
            workspaceId: workspace.id,
            portBase: workspace.portBase,
            casperDirectory: casperDirectory,
            basePath: ProcessInfo.processInfo.environment["PATH"],
            controlSocketPath: controlSocketPath,
            sessionName: sessionIdentity.name
        )
        // Export a UTF-8 LANG so terminals decode UTF-8 instead of Latin-1; keep
        // Casper's own vars on any collision (there are none today).
        config.environment.merge(TerminalLocale.environment()) { existing, _ in existing }
        return config
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
            branch: branch, remoteURL: remote,
            // Canonicalized (not just standardized) because it is compared across
            // folders reached by different spellings — see `spaceSharingRepository`.
            commonDirPath: canonicalPath(repo.commonDirPath),
            isLinkedWorktree: repo.isLinkedWorktree)
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

    /// Detection cadence while the window is visible — fast enough to keep the
    /// sidebar's live state and spinners responsive.
    nonisolated static let agentDetectionIntervalVisible: Duration = .milliseconds(250)
    /// Detection cadence while the window is hidden — slow, but never stopped, so
    /// a run that completes off-screen still fires its background notification.
    nonisolated static let agentDetectionIntervalHidden: Duration = .milliseconds(1000)

    /// The scrape interval for the current visibility. Throttles 4× when hidden.
    /// Note: the resolver debounces in *ticks* (`debounce: 2`), so a hidden
    /// completion is accepted after ~2 s instead of ~0.5 s — acceptable, since
    /// nothing visible depends on it and the notification is the only consumer.
    nonisolated static func agentDetectionInterval(isWindowVisible: Bool) -> Duration {
        isWindowVisible ? agentDetectionIntervalVisible : agentDetectionIntervalHidden
    }

    /// Start the periodic terminal-scraping detector, throttled to ~1s while the
    /// window is hidden (see `agentDetectionInterval`) and ~0.25s while visible.
    /// Idempotent: a second call while a loop is already running is a no-op.
    func startAgentDetection() {
        guard agentDetectionTask == nil else { return }
        agentDetectionTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.runAgentDetectionTick()
                let visible = self?.isWindowVisible ?? true
                try? await Task.sleep(for: AppModel.agentDetectionInterval(isWindowVisible: visible))
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
    /// last known state. The selected workspace is scraped at full cadence;
    /// non-selected workspaces are scraped only every `backgroundDetectionStride`
    /// ticks to keep this main-actor pass cheap.
    func runAgentDetectionTick() {
        detectionTickCount &+= 1
        let scrapeBackground = detectionTickCount % Self.backgroundDetectionStride == 0
        for space in spaces {
            for ws in space.workspaces {
                if explicitAuthority.contains(ws.id) { continue }  // detection stopped for W
                let isSelected = (ws.id == selectedWorkspaceID)
                if !isSelected && !scrapeBackground { continue }  // background: reduced sub-cadence

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
              workspace(at: at).agentState != state else { return }
        let previous = workspace(at: at).agentState
        // agentState is transient (deliberately not encoded by Session's Codable),
        // so the @Observable mutation refreshes the sidebar with no need to persist.
        updateWorkspace(at: at) { $0.agentState = state }
        clearNotificationOnResume(from: previous, to: state, at: at)
        // A detected transition into an attention state raises the same notification
        // `casper notify` would — a real macOS notification plus the sidebar dot — so
        // the user is alerted without installing any agent hook. Reached only on an
        // actual change thanks to the guard above (edge-triggered, no extra dedup).
        if let message = Self.notificationMessage(for: state) {
            controlRaiseNotification(message: message, for: workspaceID)
        }
    }

    /// On a `done → working` resume, clear the stale "Done" notification entirely:
    /// both the caption (`pendingNotificationMessage`) and the LED
    /// (`pendingNotification`), so the sidebar bubble goes away once the agent picks
    /// the task back up. A no-op for any other transition.
    private func clearNotificationOnResume(
        from previous: AgentState, to state: AgentState, at: WorkspaceIndex) {
        guard previous == .done, state == .working else { return }
        updateWorkspace(at: at) {
            $0.pendingNotificationMessage = nil
            $0.pendingNotification = false
        }
    }

    /// The notification text for a detected state, or `nil` when the state needs
    /// no attention. Only `blocked` and `done` alert the user; the rest are silent.
    /// Exhaustive by design so a new `AgentState` case forces a decision here.
    private static func notificationMessage(for state: AgentState) -> String? {
        switch state {
        case .blocked: return "Waiting for your input"
        case .done: return "Done"
        case .error: return "Something went wrong"
        case .working, .idle, .unknown: return nil
        }
    }

    /// The interruption level for a notification raised from a given state. `done`
    /// is informational — the user finished task arrives quietly in Notification
    /// Center (`.passive`: no banner, no sound). Every state that reaches delivery
    /// with a message (`blocked`, `error`) requires action, so it interrupts
    /// (`.active`: banner + sound). States that never notify still map to `.active`
    /// as a harmless default; only `done` needs the quieter treatment.
    private static func interruptionLevel(for state: AgentState) -> UNNotificationInterruptionLevel {
        state == .done ? .passive : .active
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
        let previous = workspace(at: at).agentState
        updateWorkspace(at: at) { $0.agentState = state }
        clearNotificationOnResume(from: previous, to: state, at: at)
        // The explicit CLI path is the ONLY place authority is granted: once an
        // agent reports its own state, terminal-scraping detection steps aside for
        // this workspace. Robust authority release is deferred to a later timeout
        // mechanism.
        explicitAuthority.insert(workspaceID)
        // `done` is the one explicit state detection can never produce for a
        // hook-driven workspace (it's already under explicit authority by the
        // time a Stop hook fires — see
        // `.superpowers/themes/agent-state-detection.md` § Authority), so this
        // is the only place that can raise its attention bubble/notification.
        // `blocked`/`error` are deliberately excluded: both already get an
        // explicit `casper notify` from their own callers (`notification.py`,
        // the `casper-status` skill), so mirroring this for them would double
        // the notification.
        if state == .done {
            controlRaiseNotification(message: Self.notificationMessage(for: .done), for: workspaceID)
        }
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
        // `todos` is transient (Session's Codable never encodes it), so there is
        // nothing to persist. Skip the mutation entirely when the synthesized
        // todos are unchanged — an agent streams progress on a hot path, and
        // `spaces` has no observation sub-granularity, so an unconditional write
        // would re-render the whole sidebar + detail for no change.
        if workspace(at: at).todos == todos { return true }
        updateWorkspace(at: at) { $0.todos = todos }
        return true
    }

    @discardableResult
    func controlClearProgress(for workspaceID: UUID) -> Bool {
        guard let at = locate(workspaceID) else { return false }
        // Transient field (see `controlSetProgress`); nothing to persist, and skip
        // the re-render when the todos are already empty.
        if workspace(at: at).todos.isEmpty { return true }
        updateWorkspace(at: at) { $0.todos = [] }
        return true
    }

    /// Raise a workspace notification. Both the persistent attention bubble and the
    /// macOS notification (when a message is given) are suppressed when the target is
    /// focused (selected AND the window is key) — the user is already looking at it.
    /// When raised, the message (if any) is also stored on the workspace so the
    /// sidebar can display it, mirrored by `clearNotificationForFocusedWorkspace`.
    ///
    /// Returns `false` when no such workspace exists, `true` otherwise. The attention
    /// bubble and the macOS notification are only delivered when the target is not
    /// already focused.
    @discardableResult
    func controlRaiseNotification(message: String?, for workspaceID: UUID) -> Bool {
        guard let at = locate(workspaceID) else { return false }
        // The attention bubble and the macOS notification both draw the eye to a
        // workspace you are NOT looking at. If the target is already focused
        // (selected AND the window is key), raising either is noise, so skip both.
        let focused = (workspaceID == selectedWorkspaceID) && isWindowKey()
        if !focused {
            updateWorkspace(at: at) {
                $0.pendingNotification = true
                $0.pendingNotificationMessage = message
            }
        }
        // A notification means "look at this workspace". If its owning Space is
        // collapsed, the workspace row (and any attention bubble) is hidden, so expand
        // the Space to surface it — regardless of focus, since the user may have
        // collapsed a Space that still contains the selection. Guard on isCollapsed to
        // avoid a redundant no-op animation.
        if spaces[at.space].isCollapsed {
            withAnimation(.snappy) { spaces[at.space].isCollapsed = false }
        }
        if let message, !focused, !isWithinNotificationCooldown(workspaceID) {
            // The interruption level follows the workspace's current agent state: the
            // detection path sets it just before calling here, and the explicit CLI
            // path (`casper notify`) reflects whatever the last `casper status set`
            // reported — so the workspace state is the single source of truth for both.
            let state = workspace(at: at).agentState
            deliverNotification(
                workspace(at: at).name, message, workspaceID,
                Self.interruptionLevel(for: state))
            lastNotifiedAt[workspaceID] = Date()
        }
        persist()
        return true
    }

    /// Whether `workspaceID` delivered a notification within the last
    /// `notificationCooldown`, in which case a repeat should be suppressed.
    private func isWithinNotificationCooldown(_ workspaceID: UUID) -> Bool {
        guard let last = lastNotifiedAt[workspaceID] else { return false }
        return Date().timeIntervalSince(last) < Self.notificationCooldown
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
        guard workspace(at: at).pendingNotification else { return }
        updateWorkspace(at: at) {
            $0.pendingNotification = false
            $0.pendingNotificationMessage = nil
        }
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

    /// Why a `casper run <name>` request could not launch a command.
    struct ControlRunError: Error, Equatable {
        let message: String
    }

    /// Open a new terminal in `workspaceID` by splitting its top-left surface.
    /// Mirrors the toolbar's "new terminal" action, but targeted at an arbitrary
    /// (non-selected) workspace, and allows overriding the working directory
    /// (defaults to the workspace's worktree) and running a command. The caller
    /// chooses the split `orientation`, defaulting to `.vertical` (split-down).
    @discardableResult
    func controlOpenTerminal(
        in workspaceID: UUID, command: String? = nil, cwd: String? = nil,
        orientation: LayoutNode.Orientation = .vertical
    ) -> ControlTerminalInfo? {
        guard let ws = workspace(id: workspaceID),
              let anchor = LayoutTree.surfaceIDs(ws.layout).first,
              let at = locateSurface(anchor) else { return nil }
        let resolvedCwd = cwd ?? ws.worktreePath
        let surface = Surface.terminal(cwd: resolvedCwd)
        if let command { pendingInitialInput[surface.id] = command }
        insertSurfaceBySplitting(
            at: at, focused: anchor, orientation: orientation, side: .after, surface: surface)
        // A background (non-selected) workspace's views never mount on their own, so a
        // queued command would otherwise never run. Bring its pending surfaces up off-screen
        // now — mirroring the silent-creation path in createLinkedWorkspace. Re-fetch the
        // workspace fresh: the earlier `ws` predates the split and lacks the new surface.
        if command != nil, selectedWorkspaceID != workspaceID, let refreshed = workspace(id: workspaceID) {
            materializePendingSurfacesOffscreen(in: refreshed)
        }
        return ControlTerminalInfo(id: surface.id.uuidString, cwd: resolvedCwd)
    }

    // MARK: - `.casper.json` lifecycle hooks

    /// The `setup`/`teardown` hook machinery: the visible hook splits, the child-exit
    /// correlation, and the once-latched teardown prune. Lazy so the injected closures
    /// can capture a fully-initialized `self`; all three capture it WEAKLY, because
    /// this model owns the runner and a strong capture would close the retain cycle.
    @ObservationIgnored private lazy var scriptHooks = ScriptHookRunner(
        insertSurface: { [weak self] workspaceID, surface, command in
            self?.insertHookSurface(surface, in: workspaceID, command: command) ?? false
        },
        worktreePath: { [weak self] id in self?.workspace(id: id)?.worktreePath },
        reportSetupFailure: { [weak self] id in self?.setDetectedAgentState(.error, for: id) })

    /// Insert `surface` into `workspaceID` as a visible split-down (top/bottom stack),
    /// running `command` (already hook-wrapped by the runner) on first mount. Returns
    /// false if the workspace/anchor can't be resolved. The layout mutation and the
    /// queued-input map live here; the hook policy lives in `ScriptHookRunner`, which
    /// owns the surface's identity so it can tag it before this split runs.
    private func insertHookSurface(_ surface: Surface, in workspaceID: UUID, command: String) -> Bool {
        guard let ws = workspace(id: workspaceID),
              let anchor = LayoutTree.surfaceIDs(ws.layout).first,
              let at = locateSurface(anchor) else { return false }
        pendingInitialInput[surface.id] = command
        insertSurfaceBySplitting(
            at: at, focused: anchor, orientation: .vertical, side: .after, surface: surface)
        // A background (non-selected) workspace's views never mount on their own, so the
        // split just inserted would get no `GhosttySurfaceView`, no PTY, and the hook would
        // never run — leaving `runTeardown` to end on its 30 s timeout on every delete of an
        // unselected workspace. Bring it up off-screen now, mirroring the queued-command
        // paths in `controlOpenTerminal` / `createLinkedWorkspace`. Re-fetch the workspace
        // fresh: the `ws` above predates the split and lacks the new surface.
        if selectedWorkspaceID != workspaceID, let refreshed = workspace(id: workspaceID) {
            materializePendingSurfacesOffscreen(in: refreshed)
        }
        return true
    }

    /// Called when a surface's child process exits (via GhosttySurfaceView.onChildExit).
    /// A no-op for ordinary panes (those not tagged in the runner's `scriptSurfaces`) —
    /// which matters precisely here, because every `GhosttySurfaceView` calls this on
    /// every child exit, hook split or not.
    func handleScriptSurfaceExit(_ surfaceID: UUID, code: Int32) {
        scriptHooks.handleScriptSurfaceExit(surfaceID, code: code)
    }

    /// How a workspace's `teardown` lifecycle hook ended, re-exported so this model's
    /// close/delete API can be read without reaching into the runner's namespace.
    typealias TeardownHookStatus = ScriptHookRunner.TeardownHookStatus

    /// The workspace's resolved `teardown` hook command, or nil when it has no
    /// `.casper.json` or no `teardown` script. Each destroy path resolves it once and
    /// hands it to `runTeardown`, so the config file is read exactly once per close.
    /// Stays here rather than on the runner, which knows workspaces only by id and
    /// deliberately nothing about the `Workspace` model.
    func teardownCommand(for ws: Workspace) -> String? {
        (try? RepoConfig.load(fromRepoRoot: ws.worktreePath))??.teardownScript()
    }

    /// Run the workspace's `teardown` lifecycle hook (if any) and wait for its outcome.
    /// See `ScriptHookRunner.runTeardown`.
    func runTeardown(id workspaceID: UUID, command: String?) async -> TeardownHookStatus {
        await scriptHooks.runTeardown(id: workspaceID, command: command)
    }

    /// Run the named command `name` (defaulting to `run`) from the workspace's
    /// `.casper.json` in a new visible terminal. Refuses reserved lifecycle names
    /// and unknown commands with a clear message.
    func controlRun(name: String?, in workspaceID: UUID) -> Result<ControlTerminalInfo, ControlRunError> {
        guard let ws = workspace(id: workspaceID) else {
            return .failure(ControlRunError(message: "workspace not found"))
        }
        let requested = name ?? "run"
        let config: RepoConfig
        do {
            guard let loaded = try RepoConfig.load(fromRepoRoot: ws.worktreePath) else {
                return .failure(ControlRunError(message: "no .casper.json in this workspace"))
            }
            config = loaded
        } catch let error as RepoConfigError {
            return .failure(ControlRunError(message: "Invalid .casper.json: \(error.reason)"))
        } catch {
            return .failure(ControlRunError(message: error.localizedDescription))
        }
        switch config.resolveRunCommand(requested) {
        case .denied(let message):
            return .failure(ControlRunError(message: message))
        case .command(let command):
            guard let info = controlOpenTerminal(
                in: workspaceID, command: ScriptHookRunner.subshellWrappedScriptCommand(command), cwd: nil,
                orientation: .vertical)
            else {
                return .failure(ControlRunError(message: "cannot open terminal"))
            }
            return .success(info)
        }
    }

    /// List the terminal surfaces of `workspaceID` in visual (depth-first) order.
    /// Non-terminal leaves (none exist in a layout today, but the filter stays
    /// defensive) are skipped.
    func controlListTerminals(in workspaceID: UUID) -> [ControlTerminalInfo] {
        guard let ws = workspace(id: workspaceID) else { return [] }
        return LayoutTree.surfaces(ws.layout).compactMap { surface in
            guard case .terminal(let cwd) = surface.kind else { return nil }
            return ControlTerminalInfo(id: surface.id.uuidString, cwd: cwd)
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
    /// Like `controlLoadBrowser`, it drives a create-or-navigate on the cached
    /// coordinator, so a repeat open with a different URL actually navigates the
    /// already-shown web view instead of silently keeping the previous page.
    @discardableResult
    func controlOpenBrowser(url: URL, in workspaceID: UUID) -> Bool {
        guard let at = locate(workspaceID) else { return false }
        // Reuse the existing browser surface id (like `setBrowserURL`) so the cached
        // `BrowserCoordinator`/`WKWebView` keyed on it is preserved rather than leaked,
        // keeping the page and its history across reopens.
        let existingID = workspace(at: at).inspector.browser.id
        let surface = Surface(id: existingID, kind: .browser(url: url))
        updateWorkspace(at: at) { $0.inspector.browser = surface }
        setInspectorTab(.browser, for: workspaceID)   // selects the browser tab, expands, persists
        // A coordinator that already exists won't be re-initialized by the SwiftUI
        // view, so it won't pick up the new URL on its own: create-or-navigate it
        // explicitly. A freshly-created coordinator already loads the surface's URL
        // at init, so only navigate again when it pre-existed — avoiding a redundant
        // double load. (Same logic as `controlLoadBrowser`; the difference is that
        // this method also selects and expands the browser tab above.)
        let existed = browserCoordinators[existingID] != nil
        if let coordinator = browserCoordinator(for: surface), existed {
            coordinator.load(url)
        }
        return true
    }

    /// Load `url` into `workspaceID`'s inspector browser surface WITHOUT touching
    /// the inspector: unlike `controlOpenBrowser`, it never selects the browser tab
    /// or expands the panel, so it drives a hidden/unselected browser in the
    /// background (useful for parallel automation of a browser that isn't visible).
    @discardableResult
    func controlLoadBrowser(url: URL, in workspaceID: UUID) -> Bool {
        guard let at = locate(workspaceID) else { return false }
        // Reuse the existing browser surface id (like `controlOpenBrowser`) so the
        // cached coordinator/web view keyed on it is preserved across loads.
        let existingID = workspace(at: at).inspector.browser.id
        let surface = Surface(id: existingID, kind: .browser(url: url))
        updateWorkspace(at: at) { $0.inspector.browser = surface }
        scheduleSave()   // persist the new URL exactly like `setBrowserURL`
        // The panel may be hidden/unselected, so the SwiftUI view won't lazily
        // create the coordinator: create-or-navigate it explicitly. A freshly-created
        // coordinator already loads the surface's URL at init, so only navigate again
        // when it pre-existed — avoiding a redundant double load.
        let existed = browserCoordinators[existingID] != nil
        if let coordinator = browserCoordinator(for: surface), existed {
            coordinator.load(url)
        }
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
        let worktree = workspace(at: at).worktreePath
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

    /// Collapse the inspector if `workspaceID`'s active tab is `.browser`.
    /// No-op (still succeeds) if the diff tab is active or the panel is
    /// already collapsed — the caller's goal ("browser not showing") already
    /// holds either way.
    @discardableResult
    func controlCloseBrowser(in workspaceID: UUID) -> Bool {
        guard let ws = workspace(id: workspaceID) else { return false }
        if ws.inspector.tab == .browser {
            setInspectorCollapsed(true, for: workspaceID)
        }
        return true
    }

    /// Collapse the inspector if `workspaceID`'s active tab is `.diff`.
    /// Mirrors `controlCloseBrowser`.
    @discardableResult
    func controlCloseDiff(in workspaceID: UUID) -> Bool {
        guard let ws = workspace(id: workspaceID) else { return false }
        if ws.inspector.tab == .diff {
            setInspectorCollapsed(true, for: workspaceID)
        }
        return true
    }

    // MARK: - Browser automation (release control channel)

    /// The browser-automation control-channel ops (`screenshot`, `eval`, `content`,
    /// `url`, `click`, `scroll`, `type`, `key`, `console`, `wait`, `reload`), which
    /// only read the model and drive an already-existing browser surface. Lazy so the
    /// injected closures can capture a fully-initialized `self`; both capture it
    /// WEAKLY, because this model owns the controller and a strong capture would close
    /// the retain cycle. The verbs that mutate `spaces` or the inspector
    /// (`controlOpenBrowser`, `controlLoadBrowser`, `controlCloseBrowser`) stay here.
    @ObservationIgnored private(set) lazy var browserAutomation = BrowserAutomationController(
        resolveWorkspace: { [weak self] id in self?.workspace(id: id) },
        coordinator: { [weak self] surface in self?.browserCoordinator(for: surface) })

    /// Create a linked workspace in the Space that owns `workspaceID` (the control
    /// channel's "create workspace" verb, targetable from any workspace in that
    /// Space, not just the primary).
    func controlCreateWorkspace(
        inSpaceOf workspaceID: UUID, branch: String, base: String?, command: String? = nil
    ) -> Result<ControlWorkspaceInfo, WorkspaceCreationError> {
        guard let ws = workspace(id: workspaceID), let space = space(for: ws) else {
            return .failure(WorkspaceCreationError(message: "no target workspace"))
        }
        return createLinkedWorkspace(spaceID: space.id, name: branch, base: base, command: command, select: false)
            .map { ControlWorkspaceInfo(id: $0.id.uuidString, name: $0.name, branch: $0.branch, path: $0.worktreePath) }
    }

    /// Run one `WorktreeManager` call off the main actor and await its result.
    ///
    /// Every git call on the close/delete path goes through here, so the main actor stays
    /// free and the progress sheet can actually animate. Detaching is safe:
    /// `WorktreeManager`'s entry points are `nonisolated static func`s on an `enum` taking
    /// `Sendable` `String`s and returning `Sendable` values; each one opens its own
    /// `Repository`, so no libgit2 object ever crosses a thread; `Libgit2.ensureInit` is a
    /// lazy `static let`, whose initialization is thread-safe; and `git_error_last` is
    /// thread-local, read by `gitCheck` on the very thread that made the failing call.
    ///
    /// What is deliberately NOT offloaded is every touch of the model — `removeWorkspace`,
    /// selection, port release, view disposal all stay on the main actor. This runs the
    /// libgit2/filesystem work and nothing else.
    private static func offloadGit<T: Sendable>(
        _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: body).value
    }

    /// The progress reporter for one close/delete run, wired to the published
    /// `closeProgress` and to the step test hook. Weak captures because the reporter
    /// outlives nothing but the operation, while `AppModel` is app-lifetime.
    private func makeCloseProgressReporter(
        id workspaceID: UUID, title: String, stepCount: Int
    ) -> WorkspaceCloseProgressReporter {
        WorkspaceCloseProgressReporter(
            id: workspaceID, title: title, stepCount: stepCount,
            publish: { [weak self] in self?.closeProgress = $0 },
            published: { [weak self] in self?.closeProgress },
            onStep: { [weak self] in self?.onCloseProgressForTest?($0) })
    }

    /// Destroy a LINKED workspace: prune its worktree (deletes the folder),
    /// delete its branch in the origin repo, then drop it from the UI. Refuses a
    /// primary workspace. Git cleanup runs BEFORE the UI removal so a git failure
    /// leaves the workspace intact and retryable. Removal must precede the branch
    /// delete (a checked-out branch cannot be deleted); `WorktreeManager.remove`
    /// guarantees the working-tree directory is gone from disk even with read-only
    /// entries or a dangling admin entry, and the branch delete is idempotent.
    /// Shared by the
    /// `casper workspace delete` control-channel verb and the sidebar's "Merge and
    /// Close Workspace…"/"Delete Workspace…" actions.
    @discardableResult
    private func pruneWorkspaceFromDisk(id workspaceID: UUID) async -> Result<Void, WorkspaceDeleteError> {
        guard let at = locate(workspaceID) else {
            return .failure(WorkspaceDeleteError(message: "workspace not found"))
        }
        guard workspace(at: at).kind == .linked else {
            return .failure(WorkspaceDeleteError(message: "cannot delete the primary workspace"))
        }
        let repoPath = spaces[at.space].folderPath
        let branch = workspace(at: at).branch
        let worktreePath = workspace(at: at).worktreePath
        do {
            // Both git calls share one detached hop (see offloadGit) because their order
            // is load-bearing: a checked-out branch cannot be deleted, so the worktree
            // must go first.
            try await Self.offloadGit {
                // Casper's own worktrees are registered under their branch name, but an
                // adopted one (created outside Casper) can carry any name, so the admin
                // entry is resolved by path — falling back to the branch when the repo
                // lists nothing there, which is what the removal below expects anyway.
                let entry = WorktreeManager.registeredName(
                    repoPath: repoPath, worktreePath: worktreePath) ?? branch
                try WorktreeManager.remove(repoPath: repoPath, name: entry, worktreePath: worktreePath)
                try WorktreeManager.deleteBranch(repoPath: repoPath, name: branch)
            }
        } catch {
            return .failure(WorkspaceDeleteError(message: "delete failed: \(error)"))
        }
        removeWorkspace(id: workspaceID)   // back on the main actor: drops from UI, releases port, discards views
        return .success(())
    }

    /// The control channel's delete verb. Keeps a completion-based shape because
    /// `ControlServer` replies from a synchronous `handle`; the work itself is the
    /// shared async core. Deliberately silent — no progress sheet, no teardown-hook
    /// notification: this path is driven remotely and already reports back as JSON.
    func controlDeleteWorkspace(
        id workspaceID: UUID, completion: @escaping (Result<Void, WorkspaceDeleteError>) -> Void
    ) {
        Task { @MainActor in
            completion(await self.deleteLinkedWorkspace(id: workspaceID, reportsProgress: false) {
                await self.pruneWorkspaceFromDisk(id: workspaceID)   // precise error, no teardown
            })
        }
    }

    /// Shared linked-workspace teardown-then-prune flow behind `deleteWorkspace`
    /// and `controlDeleteWorkspace`. Only the non-linked case differs, so each
    /// caller supplies its own `nonLinkedFallback` and keeps its exact error and
    /// return behavior.
    ///
    /// `reportsProgress` is what keeps the control channel silent while the GUI gets its
    /// modal sheet. `onTeardownHook` receives the hook's outcome — always, including
    /// `.none` and `.succeeded` — so the caller decides whether it is worth reporting;
    /// it never affects the returned result, because a broken teardown must not block
    /// the delete.
    private func deleteLinkedWorkspace(
        id workspaceID: UUID,
        reportsProgress: Bool,
        onTeardownHook: @MainActor (TeardownHookStatus) -> Void = { _ in },
        nonLinkedFallback: () async -> Result<Void, WorkspaceDeleteError>
    ) async -> Result<Void, WorkspaceDeleteError> {
        guard let ws = workspace(id: workspaceID), ws.kind == .linked else {
            return await nonLinkedFallback()
        }
        // Claim the workspace synchronously, before the first `await` below: see
        // `closingWorkspaces`.
        guard closingWorkspaces.insert(workspaceID).inserted else {
            return .failure(WorkspaceDeleteError(message: "deletion already in progress"))
        }
        defer { closingWorkspaces.remove(workspaceID) }
        // Resolved once, up front: it decides the step count AND is what `runTeardown`
        // runs, so the config file is never read twice.
        let teardown = teardownCommand(for: ws)
        let progress = reportsProgress
            ? makeCloseProgressReporter(
                id: workspaceID, title: "Deleting \u{201c}\(ws.name)\u{201d}",
                stepCount: teardown == nil ? 1 : 2)
            : nil
        progress?.start()
        defer { progress?.finish() }

        if teardown != nil {
            progress?.step(
                "Running teardown hook\u{2026}",
                deadline: Date().addingTimeInterval(ScriptHookRunner.teardownTimeout))
        }
        onTeardownHook(await runTeardown(id: workspaceID, command: teardown))
        progress?.step("Removing the worktree\u{2026}")
        return await pruneWorkspaceFromDisk(id: workspaceID)
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
    ///
    /// `onTeardownHook` receives the hook's outcome — always, including `.none` and
    /// `.succeeded` — so the caller decides whether it is worth reporting; it never
    /// affects the returned outcome, because a broken teardown must not block the close.
    func closeWorkspace(
        id workspaceID: UUID,
        onTeardownHook: @MainActor (TeardownHookStatus) -> Void = { _ in }
    ) async -> WorkspaceCloseOutcome {
        guard let ws = workspace(id: workspaceID), ws.kind == .linked,
              let space = space(for: ws), space.isGitRepo,
              let baseBranch = ws.baseBranch, !baseBranch.isEmpty,
              let primary = space.workspaces.first(where: { $0.kind == .primary })
        else {
            return .mergeFailed(message: "workspace not found or has no base branch")
        }
        // Claim the workspace synchronously, before the first `await` below: see
        // `closingWorkspaces`.
        guard closingWorkspaces.insert(workspaceID).inserted else {
            return .mergeFailed(message: "This workspace is already being closed.")
        }
        defer { closingWorkspaces.remove(workspaceID) }
        // Read the model here, on the main actor, so the detached git calls below capture
        // plain strings and never reach back into it.
        let worktreePath = ws.worktreePath
        let primaryPath = primary.worktreePath
        let repoPath = space.folderPath
        let branch = ws.branch
        // Resolved once, up front: it decides the step count AND is what `runTeardown`
        // runs, so the config file is never read twice.
        let teardown = teardownCommand(for: ws)
        let progress = makeCloseProgressReporter(
            id: workspaceID, title: "Closing \u{201c}\(ws.name)\u{201d}",
            stepCount: teardown == nil ? 4 : 5)
        progress.start()
        defer { progress.finish() }

        progress.step("Checking for uncommitted changes\u{2026}")
        guard (try? await Self.offloadGit { try WorktreeManager.isClean(repoPath: worktreePath) }) == true
        else {
            return .mergeFailed(
                message: "\u{201c}\(ws.name)\u{201d} has uncommitted changes. Commit or discard "
                    + "them before merging.")
        }
        guard (try? await Self.offloadGit { try WorktreeManager.isClean(repoPath: primaryPath) }) == true
        else {
            return .mergeFailed(
                message: "\u{201c}\(primary.name)\u{201d} (branch \u{201c}\(baseBranch)\u{201d}) has "
                    + "uncommitted changes. Commit or discard them there before merging.")
        }
        progress.step("Merging \u{201c}\(branch)\u{201d} into \u{201c}\(baseBranch)\u{201d}\u{2026}")
        do {
            try await Self.offloadGit {
                _ = try WorktreeManager.merge(
                    repoPath: repoPath, branch: branch, into: baseBranch,
                    message: "Merge branch '\(branch)' into \(baseBranch)")
            }
        } catch {
            CasperLog.app.failure("close workspace: merge failed", error)
            return .mergeFailed(
                message: "The merge into \u{201c}\(baseBranch)\u{201d} could not be completed "
                    + "automatically. Resolve it manually (e.g. in a terminal), then try again. "
                    + "Nothing was deleted.")
        }
        // Merge done; the worktree still exists so teardown has a valid cwd. Run it,
        // then prune + resync.
        if teardown != nil {
            progress.step(
                "Running teardown hook\u{2026}",
                deadline: Date().addingTimeInterval(ScriptHookRunner.teardownTimeout))
        }
        onTeardownHook(await runTeardown(id: workspaceID, command: teardown))
        progress.step("Removing the worktree\u{2026}")
        if case .failure(let error) = await pruneWorkspaceFromDisk(id: workspaceID) {
            CasperLog.app.failure("close workspace: disk cleanup failed", error)
            return .cleanupFailed(
                message: "The merge succeeded, but the worktree or branch could not be removed "
                    + "from disk: \(error.message)")
        }
        // The primary is guaranteed clean at this point (checked above), so the
        // resync is unconditional: mergeBranchHeadless never runs git_checkout,
        // so without this the primary's `git status` would show the just-merged
        // files as `deleted:` until someone checks out manually.
        progress.step("Updating \u{201c}\(baseBranch)\u{201d}\u{2026}")
        do {
            try await Self.offloadGit { try WorktreeManager.resyncWorkingTree(repoPath: primaryPath) }
        } catch {
            CasperLog.app.failure("close workspace: primary worktree resync failed", error)
        }
        return .success
    }

    /// Delete a linked workspace from disk without merging: prune its worktree,
    /// delete its branch, then drop it from the UI. Never presents UI itself —
    /// see `closeWorkspace`.
    func deleteWorkspace(
        id workspaceID: UUID,
        onTeardownHook: @MainActor (TeardownHookStatus) -> Void = { _ in }
    ) async -> Result<Void, WorkspaceDeleteError> {
        await deleteLinkedWorkspace(
            id: workspaceID, reportsProgress: true, onTeardownHook: onTeardownHook
        ) {
            .failure(WorkspaceDeleteError(message: "workspace not found"))
        }
    }
}
