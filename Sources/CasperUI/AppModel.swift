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
    // Read from AppModel+Spaces.swift and AppModel+Control.swift.
    private(set) var spaces: [Space] { didSet { refreshMenuFlags() } }
    var selectedWorkspaceID: UUID? { didSet { refreshMenuFlags() } }

    /// The one write path to `spaces` from `AppModel`'s extension files, which
    /// cannot reach the `private(set)` setter directly. `didSet` fires once when
    /// `body` returns, exactly as it does for a direct mutation.
    func mutateSpaces(_ body: (inout [Space]) -> Void) { body(&spaces) }

    /// The parent directory the user last created a Space in, restored from the
    /// session so the creation panel reopens there; nil until a first Space is
    /// created that way.
    ///
    /// Plain stored state with no save trigger of its own: it reaches disk only
    /// because some later `persist()` picks it up. Whoever assigns it therefore owns
    /// the ordering — assign before creating, then make sure a save follows on every
    /// path, so the location survives a creation that fails. A creation that succeeds
    /// needs no save of its own: adopting the new Space persists the session and
    /// carries this along with it.
    ///
    /// Observed on purpose: it is written once per creation and read only when the
    /// panel is presented, so observation costs nothing here, while
    /// `@ObservationIgnored` would silently strand a view that samples it before the
    /// restore lands.
    var lastNewSpaceLocation: String?

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

    /// What the window's floor is built from, or `nil` when no workspace is on
    /// screen. Published by `WorkspaceDetailView`, which is the only place that can
    /// measure it; consumed by `WindowFloor`.
    ///
    /// `@ObservationIgnored` on purpose — it is written from a layout callback on
    /// every geometry change, and a SwiftUI view observing it would invalidate itself
    /// mid-layout. Its consumer is AppKit, which needs no observation.
    @ObservationIgnored private(set) var terminalHostMetrics: TerminalHostMetrics?

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
    /// Set by `requestDiffScroll` / read by `DiffSurfaceView`. Observable so the
    /// view reacts; not part of any persisted model.
    private(set) var diffScrollTarget: DiffScrollTarget?
    @ObservationIgnored private var diffScrollNonce = 0

    // Reached from AppModel+Control.swift.
    /// Ask `DiffSurfaceView` to scroll `workspaceID`'s diff to `file`.
    ///
    /// The nonce bump and the target write belong together: the nonce is what
    /// makes a repeated request for the same file a *distinct* target value, so
    /// the view re-scrolls instead of ignoring an unchanged one.
    func requestDiffScroll(workspaceID: UUID, file: String) {
        diffScrollNonce += 1
        diffScrollTarget = DiffScrollTarget(workspaceID: workspaceID, file: file, nonce: diffScrollNonce)
    }

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

    // Reached from AppModel+Spaces.swift.
    /// Per-workspace watcher wiring, cached because `armWorktreeWatcher` runs far more
    /// often than the answer changes — see `watcherPaths(for:isGitRepo:)`.
    @ObservationIgnored var watcherPathsCache: [UUID: WatcherPaths] = [:]

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
    private struct MenuFlagsFingerprint {
        struct WorkspaceFingerprint {
            let id: UUID
            let kind: WorkspaceKind
        }
        struct SpaceFingerprint {
            let isGitRepo: Bool
            /// In `Space.workspaces` order, so the comparison can walk both in step.
            let workspaces: [WorkspaceFingerprint]
        }
        let selectedWorkspaceID: UUID?
        let spaces: [SpaceFingerprint]
    }

    /// Last fingerprint `refreshMenuFlags()` acted on. `nil` sentinel never matches the
    /// current state, so the first call (seeded at the end of `init`) always proceeds
    /// rather than being skipped.
    @ObservationIgnored private var lastMenuFlagsFingerprint: MenuFlagsFingerprint?

    /// Build the current menu-flags fingerprint in a single pass over `spaces`.
    private func menuFlagsFingerprint() -> MenuFlagsFingerprint {
        let spaceFingerprints = spaces.map { space in
            MenuFlagsFingerprint.SpaceFingerprint(
                isGitRepo: space.isGitRepo,
                workspaces: space.workspaces.map {
                    MenuFlagsFingerprint.WorkspaceFingerprint(id: $0.id, kind: $0.kind)
                })
        }
        return MenuFlagsFingerprint(
            selectedWorkspaceID: selectedWorkspaceID, spaces: spaceFingerprints)
    }

    /// Whether the current state still matches `fingerprint`, compared by walking both
    /// in step and bailing on the first difference.
    ///
    /// Deliberately not `==` on a freshly built fingerprint: this runs on every single
    /// `spaces` mutation, including a divider drag's 60–120 writes per second, and
    /// materializing a snapshot to throw away would allocate more than the linear scans
    /// the guard exists to skip. Walking allocates nothing in the unchanged case; only a
    /// genuine change pays for a rebuild.
    ///
    /// Order-sensitive: reordering a Space's workspaces without changing membership
    /// reads as a change. That errs toward recomputing — where the flags' own guarded
    /// writes then notify no one — never toward missing a flip.
    private func matchesMenuFlagsFingerprint(_ fingerprint: MenuFlagsFingerprint) -> Bool {
        guard fingerprint.selectedWorkspaceID == selectedWorkspaceID,
              fingerprint.spaces.count == spaces.count else { return false }
        for (recordedSpace, space) in zip(fingerprint.spaces, spaces) {
            guard recordedSpace.isGitRepo == space.isGitRepo,
                  recordedSpace.workspaces.count == space.workspaces.count else { return false }
            for (recorded, workspace) in zip(recordedSpace.workspaces, space.workspaces) {
                guard recorded.id == workspace.id, recorded.kind == workspace.kind else { return false }
            }
        }
        return true
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
        if let lastMenuFlagsFingerprint, matchesMenuFlagsFingerprint(lastMenuFlagsFingerprint) { return }
        lastMenuFlagsFingerprint = menuFlagsFingerprint()

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
        // `PaneDropDelegate.dropUpdated` calls this on every drag-update callback, and
        // Swift Observation invalidates on every `set` regardless of equality — so an
        // unguarded write would re-render every pane of the workspace on each pointer
        // move, exactly while the drag needs to stay smooth.
        guard dropHoverTarget != target || dropHoverZone != zone else { return }
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
    // Reached from AppModel+Spaces.swift.
    @ObservationIgnored var portAllocator: PortAllocator
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
        AppModel.gitProbe(URL(fileURLWithPath: $0))
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
            identifier: workspaceID.casperID, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Drives the Dock icon's bounce and unread badge. Injectable for tests, which
    /// must not reach for `NSApp`.
    @ObservationIgnored var dockAttention: any DockAttentionPresenting = DockAttention()

    /// Assigned by `AppDelegate.applicationDidFinishLaunching`; nil until that
    /// startup wiring has built the Ghostty runtime and the IPC socket.
    var runtime: GhosttyRuntime?
    @ObservationIgnored var casperDirectory: String?
    @ObservationIgnored var controlSocketPath: String?

    /// Live surface views, keyed by surface id. Holds terminal
    /// (`GhosttySurfaceView`) and browser (`WKWebView`) views. Persisting these
    /// across SwiftUI rebuilds keeps each PTY or web page alive when the layout
    /// tree is restructured.
    @ObservationIgnored private var surfaceViews: [UUID: NSView] = [:]

    /// The live Ghostty view for a surface id, or nil for a browser/absent surface.
    private func ghosttyView(_ surfaceID: UUID) -> GhosttySurfaceView? {
        surfaceViews[surfaceID] as? GhosttySurfaceView
    }

    #if DEBUG
    /// Cache size for the debug memory census (`debugMemoryCounters`). An accessor
    /// rather than widened visibility, so the cache itself stays private — see the
    /// appmodel-extension-encapsulation project-memory note.
    var debugSurfaceViewCount: Int { surfaceViews.count }
    #endif

    // Reached from AppModel+Control.swift.
    /// Live browser coordinators, keyed by surface id. Each owns a browser
    /// surface's `WKWebView` and navigation state; caching them here keeps the
    /// web page and address alive across SwiftUI rebuilds.
    @ObservationIgnored var browserCoordinators: [UUID: BrowserCoordinator] = [:]

    // Reached from AppModel+Control.swift.
    /// Command to type into a terminal surface the first time its view is
    /// materialized (from `terminal new --command` / `workspace new --command`).
    /// Populated at creation (`controlOpenTerminal`, `createLinkedWorkspace`),
    /// consumed and removed on first `surfaceView(for:in:)` for that surface id
    /// — never replayed after. Never persisted: restoring `session.json` starts
    /// with an empty map, so a restored terminal comes up as a plain login shell
    /// instead of re-running its original launch command.
    @ObservationIgnored var pendingInitialInput: [UUID: String] = [:]

    /// Off-screen host window that materializes a silently-created (control-channel)
    /// workspace's terminal surfaces — those carrying queued `pendingInitialInput` —
    /// so libghostty spawns their PTY and runs the queued command even though the
    /// workspace is never selected (its real view would otherwise never mount). When
    /// the user later selects the workspace, `SharedViewOwnership` reparents the
    /// cached `GhosttySurfaceView` from here into the visible container. Created lazily.
    @ObservationIgnored private var backgroundSurfaceNursery: NSWindow?

    // Reached from AppModel+Spaces.swift.
    /// Per-workspace named commands from `.casper.json`. Filled at launch and on
    /// selection for the selected workspace, and from a sidebar row's `.onAppear`
    /// for the rest, so SwiftUI never reads the file during `body` —
    /// `namedCommands(for:)` only ever reads this cache.
    @ObservationIgnored var namedCommandsCache: [UUID: [RepoNamedCommand]] = [:]

    // Reached from AppModel+Spaces.swift.
    /// The `.casper.json` modification date each cache entry above was built from, so a
    /// filesystem-driven refresh can skip the read and the decode on an untouched file.
    @ObservationIgnored var namedCommandsStamps: [UUID: Date] = [:]

    // Reached from AppModel+WorkspaceLifecycle.swift.
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
    @ObservationIgnored var closingWorkspaces: Set<UUID> = []

    // Reached from AppModel+Spaces.swift.
    /// Per-workspace debounce/`done`-derivation state for the terminal-scraping
    /// agent detector. `AgentStateResolver` is a value type carried across ticks,
    /// so each workspace owns its own copy. Runtime-only; never persisted.
    @ObservationIgnored var agentResolvers: [UUID: AgentStateResolver] = [:]

    // Reached from AppModel+Spaces.swift and AppModel+Control.swift.
    /// Workspaces whose terminal-independent, explicit state took over: native
    /// terminal detection is suppressed only for `blocked`, `done`, and `error`.
    /// Transient — an in-memory set, never persisted, so it naturally resets to
    /// "detection" on relaunch.
    @ObservationIgnored var explicitAuthority: Set<UUID> = []

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

    // Reached from AppModel+Spaces.swift.
    /// Spaces sorted by `name` (locale-aware, case-insensitive), matching the
    /// comparator `Space.orderedWorkspaces` already uses for its own workspaces.
    /// Keeping `spaces` sorted here — rather than computing a separate display
    /// order — means every other reader (sidebar, `allWorkspaces`,
    /// `workspaceShortcutNumbers`, and `session.json` on persist) gets
    /// alphabetical order for free.
    static func sortedByName(_ spaces: [Space]) -> [Space] {
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
        self.lastNewSpaceLocation = session.lastNewSpaceLocation
        // Seeded before anything else can `persist()`: a save that ran with the set
        // still empty would wipe every dismissal the user has ever made.
        self.restoredAgentReminderDismissals = session.dismissedAgentReminders
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
        // Reserve restored port blocks so a later allocate() never collides. A base
        // the allocator refuses — out of its range, misaligned, or already held by
        // another workspace — is NOT reserved, so `allocate()` stays free to hand the
        // same block to a new workspace. That surfaces as two workspaces sharing a
        // port rather than as a failure, so it is logged; startup carries on, since a
        // single unreserved base is no reason to refuse the whole session.
        for space in session.spaces {
            for ws in space.workspaces {
                guard !self.portAllocator.reserve(ws.portBase) else { continue }
                CasperLog.app.error(
                    """
                    workspace \(ws.name, privacy: .public) (\(ws.id.uuidString, privacy: .public)): \
                    port base \(ws.portBase, privacy: .public) rejected by the allocator
                    """)
            }
        }
        // Everything that has to touch the disk — the per-Space Git probes, the editor
        // sweep, the watchers — waits for `completeLaunchSetup()`; `init` decodes and
        // selects, nothing more.
        //
        // The selection is assigned directly above rather than through
        // `selectWorkspace`, so warm its named commands here — otherwise the launch
        // selection would reach the first `body` with a cold cache.
        if let selected { refreshNamedCommands(for: selected) }
        // `spaces.didSet` has already fired for the write above that follows the
        // initializing assignment (the `isCollapsed` expansion), but a session with no
        // Space at all reaches here having never fired it, so seed the flags explicitly
        // now that all three raw inputs are assigned.
        refreshMenuFlags()
    }

    deinit {
        worktreeWatcher?.stop()
        gitMetaWatcher?.stop()
        agentDetectionTask?.cancel()
        // The integration probe is cancelled by `AgentIntegrationReminders`' own deinit —
        // reaching for it here would build the lazy controller just to tear it down.
    }

    /// All workspaces across every Space, in sidebar order.
    var allWorkspaces: [Workspace] { spaces.flatMap(\.workspaces) }

    /// Every Space paired with the workspaces the sidebar draws under it, in display
    /// order: `orderedWorkspaces` for an expanded Space, none for a collapsed one —
    /// its rows are hidden, so they are neither drawn nor eligible for a shortcut.
    ///
    /// The sidebar builds this once per body pass and derives both its rows and its
    /// shortcut hints from it, instead of sorting every Space's workspaces twice.
    func spacesWithVisibleWorkspaces() -> [(space: Space, workspaces: [Workspace])] {
        spaces.map { ($0, $0.isCollapsed ? [] : $0.orderedWorkspaces) }
    }

    /// Maps eligible workspaces to their `Cmd+N` shortcut (1-9), numbering
    /// `spacesWithVisibleWorkspaces()` in order. The single definition of the
    /// numbering: the sidebar hint labels and `selectWorkspace(atShortcutNumber:)` both
    /// go through it, on the same input, so the two can never drift apart.
    static func shortcutNumbers(for spaces: [(space: Space, workspaces: [Workspace])]) -> [UUID: Int] {
        var numbers: [UUID: Int] = [:]
        var next = 1
        for space in spaces {
            for workspace in space.workspaces {
                guard next <= 9 else { return numbers }
                numbers[workspace.id] = next
                next += 1
            }
        }
        return numbers
    }

    /// The `Cmd+N` shortcut numbers for the sidebar as it currently stands.
    var workspaceShortcutNumbers: [UUID: Int] {
        Self.shortcutNumbers(for: spacesWithVisibleWorkspaces())
    }

    /// Whether the sidebar should show the `Cmd+N` shortcut hint in place of
    /// the notification bubble. Set by `WorkspaceShortcutKeyMonitor` while
    /// Cmd is held past the reveal delay.
    var showWorkspaceShortcutHints: Bool = false

    /// Whether Option is held on its own, with no other modifier. Set by
    /// `WorkspaceShortcutKeyMonitor` on every modifier transition; read by the
    /// title bar's `MergeToolbarButton`, which becomes a Delete chip while it is
    /// down.
    var optionKeyHeld: Bool = false

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
        copyToPasteboard(workspace.worktreePath)
    }

    /// Copy a workspace's branch name to the general pasteboard. Backs the
    /// "Copy Branch Name" items in the sidebar context menu and the Edit menu.
    func copyBranchName(id: UUID) {
        guard let workspace = workspace(id: id) else { return }
        copyToPasteboard(workspace.branch)
    }

    /// Replace the general pasteboard's contents with plain text.
    private func copyToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    /// Reveal a workspace's worktree folder in Finder. Backs the "Open in
    /// Finder" items in the sidebar context menu and the Space menu.
    func openInFinder(id: UUID) {
        guard let workspace = workspace(id: id) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: workspace.worktreePath))
    }

    /// The Space a menu-bar "Create Workspace" action targets: the selected
    /// workspace's Space when it is a Git repo, otherwise the first Git Space.
    /// nil when no Git Space exists (the menu item is then disabled).
    func targetSpaceForNewWorkspace() -> Space? {
        if let id = selectedWorkspaceID, let workspace = workspace(id: id),
           let space = space(for: workspace), space.isGitRepo {
            return space
        }
        return spaces.first(where: { $0.isGitRepo })
    }

    // Reached from AppModel+Spaces.swift.
    /// The editor the currently-selected workspace remembers, carried over to a
    /// workspace being created or adopted. Must be read BEFORE the selection moves.
    var inheritedEditor: EditorKind? {
        selectedWorkspaceID.flatMap { workspace(id: $0) }?.lastUsedEditor
    }

    // Internal because `locate` / `workspace(at:)` are reached from
    // AppModel+WorkspaceLifecycle.swift and AppModel+Control.swift.
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

    // Reached from AppModel+WorkspaceLifecycle.swift and AppModel+Control.swift.
    /// Resolve the (space, workspace) index pair for in-place mutation.
    func locate(_ id: UUID) -> WorkspaceIndex? {
        indexPair { $0.id == id }
    }

    // Reached from AppModel+WorkspaceLifecycle.swift and AppModel+Control.swift.
    /// The workspace at a resolved index pair.
    func workspace(at index: WorkspaceIndex) -> Workspace {
        spaces[index.space].workspaces[index.workspace]
    }

    // Reached from AppModel+Control.swift.
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
    /// a fingerprint input must not be collapsed. The seven sites that group writes
    /// today touch only `inspector.*`, `pendingNotification*`, and `infoMarkdown` /
    /// `infoUnread`, none of which is a fingerprint input.
    func updateWorkspace(at index: WorkspaceIndex, _ body: (inout Workspace) -> Void) {
        body(&spaces[index.space].workspaces[index.workspace])
    }

    // Reached from AppModel+Control.swift.
    /// Resolve `workspaceID` and mutate its workspace in place, reporting whether it
    /// existed. The `locate` + `updateWorkspace` pair every simple per-workspace setter
    /// would otherwise repeat, so none of them can forget the guard.
    ///
    /// Only for mutations that are unconditional once the workspace resolves: a setter
    /// that must read the workspace before deciding whether to write keeps its own
    /// `locate`, because `updateWorkspace` fires `spaces`' observation whatever the body
    /// does — a "changed nothing" body still notifies every observer.
    @discardableResult
    func mutate(_ workspaceID: UUID, _ body: (inout Workspace) -> Void) -> Bool {
        guard let at = locate(workspaceID) else { return false }
        updateWorkspace(at: at, body)
        return true
    }

    func removeSpace(id: UUID) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        let removed = spaces.remove(at: index)
        for ws in removed.workspaces { retire(ws) }
        if let sel = selectedWorkspaceID, removed.workspaces.contains(where: { $0.id == sel }) {
            selectWorkspace(fallbackSelection(preferring: nil))
        }
        refreshDockAttention()
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
    func addLinkedWorkspace(spaceID: UUID, name: String) async -> Bool {
        (try? await createLinkedWorkspace(spaceID: spaceID, name: name, base: nil).get()) != nil
    }

    /// Create a linked workspace (new branch + worktree at `<parent>/<repo>-<branch>`)
    /// in a Git Space. `base` overrides the fork point; nil derives it from the
    /// primary workspace's branch (the prior behavior). `select` controls whether the
    /// new workspace becomes the selected/focused one; it defaults to true for UI
    /// creation and is set to false for the control-channel (CLI) path so a workspace
    /// created remotely does not steal the user's current selection. Returns the new
    /// workspace or a human-readable error.
    ///
    /// `async` because the checkout in the middle runs off the main actor, like every
    /// other libgit2 call on a workspace's lifecycle (`AppModel+WorkspaceLifecycle`):
    /// `WorktreeManager.create` checks out the branch AND walks the repository tree to
    /// seed the `copyFiles` entries, which is seconds of work on a large repo.
    func createLinkedWorkspace(
        spaceID: UUID, name: String, base baseOverride: String?, command: String? = nil,
        select: Bool = true
    ) async -> Result<Workspace, WorkspaceCreationError> {
        let plan: LinkedWorkspacePlan
        switch planLinkedWorkspace(spaceID: spaceID, name: name, base: baseOverride) {
        case .failure(let error): return .failure(error)
        case .success(let resolved): plan = resolved
        }
        do {
            try await Self.offloadGit { try plan.checkout() }
        } catch {
            return .failure(worktreeCreationError(error, releasing: plan))
        }
        return adoptLinkedWorkspace(plan, command: command, select: select)
    }

    /// Everything a linked-workspace creation settles before any git work starts: the
    /// validated branch name and fork point, a free sibling directory, and the port
    /// block already reserved for the workspace.
    ///
    /// `Sendable`, and identifying its Space by id rather than by index, so the checkout
    /// can run off the main actor: `spaces` stays sorted by name, so an index captured
    /// before the hop would point at a different Space if one were added meanwhile.
    private struct LinkedWorkspacePlan: Sendable {
        let spaceID: UUID
        let repoPath: String
        let branch: String
        /// The fork point, or empty for "wherever the primary's branch points".
        let base: String
        let worktreePath: String
        let portBase: Int
        let inheritedEditor: EditorKind?

        /// The libgit2 checkout this plan describes — the blocking part of creation.
        func checkout() throws {
            try WorktreeManager.create(
                repoPath: repoPath, name: branch, worktreePath: worktreePath,
                base: base.isEmpty ? nil : base)
        }
    }

    /// Validate a linked-workspace request and reserve what it needs. Pure main-actor
    /// work — it reads the model and allocates a port, and touches neither git nor the
    /// filesystem — which is what lets the caller hand the checkout to another thread.
    private func planLinkedWorkspace(
        spaceID: UUID, name: String, base baseOverride: String?
    ) -> Result<LinkedWorkspacePlan, WorkspaceCreationError> {
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
        let base = baseOverride ?? (spaces[si].primaryWorkspace?.branch ?? "")
        let folderURL = URL(fileURLWithPath: folder)
        let basePath = folderURL.deletingLastPathComponent()
            .appendingPathComponent(folderURL.lastPathComponent + "-" + branch).path

        let portBase: Int
        do { portBase = try portAllocator.allocate() } catch {
            CasperLog.app.failure("cannot add workspace: no free port block", error)
            return .failure(WorkspaceCreationError(message: "no free port block"))
        }
        // The editor carries over from the currently-active workspace (nil is fine — it
        // keeps the same resolved default), read here rather than after the checkout so
        // it reflects the workspace active when creation was requested.
        return .success(LinkedWorkspacePlan(
            spaceID: spaceID, repoPath: folder, branch: branch, base: base,
            worktreePath: availableWorktreePath(basePath), portBase: portBase,
            inheritedEditor: inheritedEditor))
    }

    /// Report a failed checkout, releasing the port block the plan had already reserved
    /// so a failed attempt cannot leak one.
    private func worktreeCreationError(
        _ error: Error, releasing plan: LinkedWorkspacePlan
    ) -> WorkspaceCreationError {
        portAllocator.release(plan.portBase)
        CasperLog.app.failure("worktree creation failed", error)
        return WorkspaceCreationError(message: error.localizedDescription)
    }

    /// Fold a finished checkout into the model: append the workspace, queue its initial
    /// command, take the selection when asked, and run the repo's `setup` hook.
    private func adoptLinkedWorkspace(
        _ plan: LinkedWorkspacePlan, command: String?, select: Bool
    ) -> Result<Workspace, WorkspaceCreationError> {
        // The Space can be discarded while the checkout runs. The worktree left on disk
        // is inert — nothing in the model points at it — so the failure is honest.
        guard let si = spaces.firstIndex(where: { $0.id == plan.spaceID }) else {
            portAllocator.release(plan.portBase)
            return .failure(WorkspaceCreationError(message: "space not found"))
        }
        var ws = WorkspaceFactory.makeLinkedWorkspace(
            name: plan.branch, worktreePath: plan.worktreePath, branch: plan.branch,
            baseBranch: plan.base, portBase: plan.portBase)
        ws.lastUsedEditor = plan.inheritedEditor
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
        if let setup = (try? RepoConfig.load(fromRepoRoot: plan.worktreePath))??.setupScript() {
            scriptHooks.runSetupHook(in: ws.id, command: setup)
        }
        // A silently-created (control-channel) workspace is never selected, so its views
        // never mount on their own. Bring the surface carrying the queued `command` up
        // off-screen so it runs now, in the background, instead of waiting for the user to
        // select the workspace. (UI creation takes the `select` path above and mounts its
        // views normally, so this is scoped to the silent path.) The `setup` split just
        // above is NOT covered here: `insertTerminal` materializes every hook split
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
        retire(ws)
        if selectedWorkspaceID == id {
            selectWorkspace(fallbackSelection(preferring: spaces[at.space]))
        }
        refreshDockAttention()
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
        // Re-selecting the workspace that is already selected is an ordinary call —
        // tapping its sidebar row, or a notification raised for it. The rest of the body
        // still matters there: it is how the attention bubble clears and how a `done`
        // workspace collapses back to `idle`. Only the two expensive steps, the
        // `.casper.json` disk read and the session encode, are gated on a real change.
        let changed = (selectedWorkspaceID != id)
        selectedWorkspaceID = id
        // Re-arm before the early return so a nil/non-Git selection stops the watcher.
        reconfigureWorktreeWatcher()
        guard let id, let ws = workspace(id: id) else { return }
        if changed { refreshNamedCommands(for: id) }
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
        if changed { persist() }
    }

    /// Switches to the workspace at `number` (1-9) in `workspaceShortcutNumbers`
    /// order, reporting whether one was there. A number with no matching workspace
    /// (e.g. `Cmd+7` with only four workspaces) is a no-op and returns false, which is
    /// what tells `WorkspaceShortcutKeyMonitor` to let the key event keep propagating
    /// — so the monitor never has to build the numbering a second time to find out.
    @discardableResult
    func selectWorkspace(atShortcutNumber number: Int) -> Bool {
        guard let match = workspaceShortcutNumbers.first(where: { $0.value == number })?.key
        else { return false }
        selectWorkspace(match)
        return true
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
        let paths = watcherPaths(for: ws, isGitRepo: spaces[at.space].isGitRepo)
        worktreeWatcher = makeWorktreeWatcher(
            ws.worktreePath, paths.exclusions, makeWorktreeChangeHandler())
        // Commit detection: watch the resolved gitdir's reflog directory, which the
        // `.git`-excluded worktree watcher above can't see. Reuse `makeWorktreeWatcher`
        // (the test injection seam) with no exclusions, routing through the same
        // debounced hop as the primary watcher.
        if let reflogDirectory = paths.reflogDirectory {
            gitMetaWatcher = makeWorktreeWatcher(reflogDirectory, [], makeWorktreeChangeHandler())
        }
    }

    /// What the FSEvents watchers for one workspace need to know about its repository.
    struct WatcherPaths {
        /// Directories FSEvents must not report changes under: `.git` plus the
        /// gitignored top-level directories (`node_modules`, `build`, …).
        let exclusions: [String]
        /// The reflog directory whose writes mean "a commit landed", or nil for a
        /// non-Git Space or a repository that could not be opened.
        let reflogDirectory: String?
    }

    /// The watcher paths for `ws`, computed once per workspace and reused.
    ///
    /// The computation is a `Repository.open` plus a directory listing and one
    /// `isPathIgnored` per top-level entry — a real cost on a large worktree, and
    /// `armWorktreeWatcher` runs on every ⌘1…9 selection and every window-occlusion
    /// transition. The answer only moves when the Space's Git backing flips or its
    /// `.gitignore` changes, both of which land in `handleSelectedWorktreeChange`,
    /// which drops the entry. Pruned with the workspace by `pruneTransientState`.
    private func watcherPaths(for ws: Workspace, isGitRepo: Bool) -> WatcherPaths {
        if let cached = watcherPathsCache[ws.id] { return cached }
        let path = ws.worktreePath
        // Open the repo once (when the Space is a Git repo) and reuse the same handle
        // for both the ignored-directory exclusions and the reflog path.
        let repo = isGitRepo ? try? Repository.open(atPath: path) : nil
        var exclusions: [String] = []
        if isGitRepo {
            exclusions.append(path + "/.git")
            if let repo {
                exclusions.append(contentsOf: (try? repo.ignoredTopLevelDirectories()) ?? [])
            }
        }
        // FSEventStreamSetExclusionPaths accepts at most 8 paths; .git stays first.
        if exclusions.count > 8 { exclusions = Array(exclusions.prefix(8)) }
        // `gitDirPath` carries a trailing slash and, for a linked worktree, resolves to
        // `<maindir>/.git/worktrees/<name>/`, so its `logs/HEAD` reflog is the one that
        // moves on this worktree's commits.
        let paths = WatcherPaths(
            exclusions: exclusions, reflogDirectory: repo.map { $0.gitDirPath + "logs" })
        watcherPathsCache[ws.id] = paths
        return paths
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
    /// The hop goes through the run loop rather than the main queue so a modal panel
    /// standing when a change lands cannot hold it back (see `MainRunLoop`).
    private func makeWorktreeChangeHandler() -> @Sendable () -> Void {
        { [weak self] in
            MainRunLoop.perform {
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
        // Anything at all may have changed under the worktree, `.gitignore` and `.git`
        // included, so the cached watcher paths stop being trustworthy here. Dropping
        // the entry (rather than recomputing) keeps the libgit2 work out of this
        // 200 ms-debounced path: the next arm pays for it, once.
        watcherPathsCache[id] = nil
        let flipped = spaces[at.space].isGitRepo
            ? demoteSpaceIfGitRemoved(spaceIndex: at.space)
            : promoteSpaceIfGitInitialized(spaceIndex: at.space)
        if flipped { armWorktreeWatcher() }   // backing changed → exclusions changed → re-arm
        diffRevision += 1
        refreshNamedCommandsIfChanged(for: id)
    }

    /// The startup work `init` deliberately leaves undone: probing every restored
    /// Space's Git backing (a libgit2 `Repository.open`, a HEAD read and an `origin`
    /// lookup per Space), detecting the launchable editors (a LaunchServices sweep),
    /// and arming the selected worktree's watchers, which read the backing the first
    /// step resolves. The cost scales with the size of the restored session and none of
    /// it is needed to draw a frame, so `AppDelegate` calls this on a later main-actor
    /// turn — see the `observed-startup-dependencies` note.
    ///
    /// Everything published here lands in an observed property (`spaces`,
    /// `availableEditors`), so a view that already rendered against the pre-launch
    /// values re-renders when the real ones arrive.
    func completeLaunchSetup() {
        resolveGitBacking()
        availableEditors = EditorLauncher.detectInstalled()
        reconfigureWorktreeWatcher()
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
            invalidateWatcherPaths(spaceIndex: si)
            if let pi = spaces[si].primaryWorkspaceIndex {
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
        // A missing primary fails safe: no promotion.
        guard spaces.indices.contains(si), !spaces[si].isGitRepo,
              let info = gitReprobe(spaces[si].folderPath),
              let pi = spaces[si].primaryWorkspaceIndex else { return false }
        spaces[si].isGitRepo = true
        spaces[si].workspaces[pi].branch = info.branch
        invalidateWatcherPaths(spaceIndex: si)
        persist()
        return true
    }

    /// Demote a Git-backed space whose repository has disappeared (e.g. its `.git`
    /// was deleted): mark it non-Git and clear the primary workspace's branch, then
    /// persist. Returns whether a demotion happened. Only ever called from a live
    /// filesystem-change event — never from a launch/selection-time probe, where a
    /// transient read failure must not be mistaken for `.git` removal.
    private func demoteSpaceIfGitRemoved(spaceIndex si: Int) -> Bool {
        // A missing primary fails safe: no demotion.
        guard spaces.indices.contains(si), spaces[si].isGitRepo,
              gitReprobe(spaces[si].folderPath) == nil,
              let pi = spaces[si].primaryWorkspaceIndex else { return false }
        spaces[si].isGitRepo = false
        spaces[si].workspaces[pi].branch = ""   // degenerate primaries carry an empty branch
        invalidateWatcherPaths(spaceIndex: si)
        persist()
        return true
    }

    /// Forget the cached watcher paths of every workspace in a Space whose Git backing
    /// just flipped: `.git` appearing or disappearing rewrites both the exclusion set
    /// and the reflog path.
    private func invalidateWatcherPaths(spaceIndex si: Int) {
        for ws in spaces[si].workspaces { watcherPathsCache[ws.id] = nil }
    }

    func focusSurface(_ id: UUID) { focusedSurfaceID = id }

    /// Move AppKit keyboard focus to the focused surface's cached view. Deferred
    /// to the next runloop turn so the view is attached to the window first: a
    /// workspace switch (or a new/closed surface) re-parents the newly active
    /// surface's view during the SwiftUI update that runs right after this state
    /// change.
    /// A no-op for surfaces with no cached `NSView` (e.g. the diff surface),
    /// which manage their own focus.
    ///
    /// The deferral goes through the run loop rather than the main queue so a modal
    /// panel standing over the app cannot hold the focus move back until it is
    /// dismissed (see `MainRunLoop`).
    private func focusActiveSurfaceView() {
        guard let id = focusedSurfaceID else { return }
        MainRunLoop.perform { [weak self] in
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
            ghosttyView(id)?.blurForLayoutChange()
            return
        }
        focusActiveSurfaceView()
    }

    // Reached from AppModel+Control.swift.
    /// The (space, workspace) index pair whose layout contains `surfaceID`.
    func locateSurface(_ surfaceID: UUID) -> WorkspaceIndex? {
        indexPair { LayoutTree.surfaceIDs($0.layout).contains(surfaceID) }
    }

    /// Whether `focusedSurfaceID` currently points at a TERMINAL pane in some
    /// workspace's layout tree. Non-layout surfaces (the Inspector browser), layout
    /// browser/diff surfaces, and "nothing focused" all return false. Gates
    /// `applyNewSplit` — Split only makes sense on a focused terminal.
    func focusedSurfaceIsTerminal() -> Bool { locateFocusedTerminal() != nil }

    /// Where the focused surface lives, but only when it is a TERMINAL pane; nil for
    /// every case `focusedSurfaceIsTerminal` rejects. One walk answers both questions
    /// the Split action asks — is a terminal focused, and which workspace owns it — so
    /// a split does not scan every Space's layout twice.
    private func locateFocusedTerminal() -> WorkspaceIndex? {
        guard let id = focusedSurfaceID else { return nil }
        for (si, space) in spaces.enumerated() {
            for (wi, ws) in space.workspaces.enumerated() {
                // `forEachSurface` rather than `surfaces(_:)`: the latter materializes a
                // fresh `[Surface]` — full values, browser URLs included — per workspace,
                // and this runs on every Cmd+D.
                var isTerminal: Bool?
                LayoutTree.forEachSurface(ws.layout) { surface in
                    guard surface.id == id else { return }
                    if case .terminal = surface.kind { isTerminal = true } else { isTerminal = false }
                }
                if let isTerminal { return isTerminal ? (space: si, workspace: wi) : nil }
            }
        }
        return nil
    }

    // Reached from AppModel+Control.swift.
    /// Shared tail of every split-based surface addition: split the leaf holding
    /// `focused` in workspace `at` to insert `surface` along `orientation`/`side`,
    /// then persist. When the split targets the currently-visible workspace it also
    /// moves focus to the new surface and re-anchors the AppKit first responder;
    /// when it targets a background workspace (e.g. `casper terminal new
    /// --workspace <other>`) the layout still changes but focus is left untouched.
    /// Callers resolve their own target and surface, then delegate here.
    func insertSurfaceBySplitting(
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
            ghosttyView(currentlyFocused)?.blurForLayoutChange()
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

    /// Add a new terminal by splitting the focused surface to the RIGHT — the New
    /// Terminal action, which splits whatever pane holds focus, terminal or not.
    func applyNewTerminal() {
        guard let focus = focusedSurfaceID else { return }
        applySplit(from: focus, direction: .right)
    }

    /// Split the given surface with a new terminal in `direction` (the pane
    /// context-menu action; always creates a terminal).
    func applySplit(from surfaceID: UUID, direction: GhosttySplitDirectionLike) {
        guard let at = locateSurface(surfaceID) else { return }
        applySplit(at: at, from: surfaceID, direction: direction)
    }

    /// Split the focused terminal in `direction` (the View menu's Split items). Those
    /// items are always enabled in the menu — never greyed — so the action itself is
    /// the gate: it does nothing unless a terminal is focused.
    func applyNewSplit(_ direction: GhosttySplitDirectionLike) {
        guard let focus = focusedSurfaceID, let at = locateFocusedTerminal() else { return }
        applySplit(at: at, from: focus, direction: direction)
    }

    /// The one implementation behind every "add a terminal by splitting" action, for a
    /// caller that has already located the workspace holding `surfaceID`.
    private func applySplit(
        at: WorkspaceIndex, from surfaceID: UUID, direction: GhosttySplitDirectionLike
    ) {
        let (orientation, side) = LayoutTree.orientationAndSide(for: direction)
        insertSurfaceBySplitting(
            at: at, focused: surfaceID, orientation: orientation, side: side,
            surface: Surface.terminal(cwd: workspace(at: at).worktreePath))
    }

    func applyCloseFocusedSurface() {
        guard let focus = focusedSurfaceID else { return }
        applyCloseSurface(focus)
    }

    /// Close the given surface (from the pane context menu, a shell exit, or the
    /// keyboard). Preserves focus on the surviving pane when a non-focused pane is
    /// closed. Closing panes never tears a workspace down: closing the last surface
    /// re-seeds the workspace with a fresh terminal, whatever its kind, so the
    /// workspace and its Space stay put. Dropping a workspace or a Space remains an
    /// explicit action (`removeWorkspace` / `removeSpace`, behind the close and
    /// delete commands).
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
        // The last surface in the workspace was closed. The workspace survives: it
        // keeps its identity, worktree and Space, and gets a fresh terminal so it is
        // never left empty. Nothing that depends on it (a worktree/branch, a Space's
        // linked workspaces) can be lost by closing panes.
        let ws = workspace(at: at)
        discardSurfaceViews(LayoutTree.surfaceIDs(ws.layout))
        let fresh = Surface.terminal(cwd: ws.worktreePath)
        updateWorkspace(at: at) { $0.layout = .leaf(fresh) }
        if wasFocused || selectedWorkspaceID == ws.id { focusedSurfaceID = fresh.id }
        persist()
        focusActiveSurfaceView()
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
        // Blur the pane that currently holds focus before the restructure, for the same
        // reason `insertSurfaceBySplitting` does: dropping a pane collapses the split it
        // left and re-nests the one it joined, and the SwiftUI re-render can detach the
        // focused view from the window before AppKit fires `resignFirstResponder` — so
        // libghostty would keep rendering a solid caret on it. `newFocus` is the moved
        // pane, which is not necessarily the one that had focus.
        if let currentlyFocused = focusedSurfaceID, currentlyFocused != newFocus {
            ghosttyView(currentlyFocused)?.blurForLayoutChange()
        }
        updateWorkspace(at: at) { $0.layout = layout }
        focusedSurfaceID = newFocus
        persist()
        focusActiveSurfaceView()
    }

    /// The persistent view for a terminal surface, created on first use. Returns nil
    /// for a non-terminal surface, before the runtime exists, when `workspaceID`
    /// resolves to no workspace, or when the surface is no longer in that workspace's
    /// layout (see the guard below).
    ///
    /// Takes the workspace id rather than the value because the workspace is needed
    /// only to build a brand-new surface's environment: every later call is a cache
    /// hit, and returning from it before reading `spaces` keeps a pane's body from
    /// observing a workspace's transient agent fields.
    func surfaceView(for surface: Surface, in workspaceID: UUID) -> GhosttySurfaceView? {
        guard let runtime, case .terminal = surface.kind else { return nil }
        if let existing = ghosttyView(surface.id) {
            return existing
        }
        guard let workspace = workspace(id: workspaceID) else { return nil }
        // Only the layout may bring a surface view into existence. `SurfaceHostView`
        // stores the `Surface` *value* it was built with, so when a pane is closed
        // SwiftUI evaluates the departing view's body one last time with that now-stale
        // value — after `applyCloseSurface` has removed the surface and
        // `discardSurfaceViews` has emptied its cache slot. Creating a view there would
        // silently refill the slot for a surface that no longer exists, and nothing
        // prunes it afterwards: every closed terminal would leak a `GhosttySurfaceView`
        // (with its process-wide key-up monitor) for the life of the process. The
        // departing pane renders `Color.black` for the nil and then disappears.
        // Deliberately below the cache-hit return above, so a live pane's every-render
        // call never pays for this walk — only genuine creation does.
        guard LayoutTree.contains(workspace.layout, id: surface.id) else { return nil }
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

    // Reached from AppModel+Control.swift.
    /// Eagerly bring up — parked off-screen — every terminal surface in `workspace`
    /// that has queued initial input, so its command (a `--command`, or a `setup`
    /// hook) runs in the background without stealing the user's current selection.
    /// Used only for control-channel (silent) creation; UI creation selects the
    /// workspace, which mounts its views the normal way. No-op until the runtime exists.
    func materializePendingSurfacesOffscreen(in workspace: Workspace) {
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
            guard let view = surfaceView(for: surface, in: workspace.id), view.window == nil else { continue }
            view.frame = host.bounds
            view.autoresizingMask = [.width, .height]
            host.addSubview(view)
        }
    }

    /// Borderless window parked far off-screen (mirrors `BrowserCapture`), sized so
    /// hosted surfaces get valid dimensions. It is deliberately never ordered on-screen:
    /// hosting a surface only needs a non-nil `window` (see
    /// `GhosttySurfaceView.viewDidMoveToWindow`), whereas an ordered window parked at
    /// -100_000 joins Mission Control's layout — its bounding box then spans ~101,000 px
    /// and every real window is scaled to nothing. Staying out of the on-screen list also
    /// means it can never become key and steal keyboard focus, and its surfaces read as
    /// occluded, so libghostty pauses their render thread (the PTY still runs).
    private func makeBackgroundSurfaceNursery() -> NSWindow {
        let frame = NSRect(x: -100_000, y: -100_000, width: 800, height: 600)
        let window = NSWindow(
            contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = NSView(frame: NSRect(origin: .zero, size: frame.size))
        backgroundSurfaceNursery = window
        return window
    }

    // Internal for AppModelTests.
    /// Visible viewport text of a live terminal surface, or nil if it has no
    /// live Ghostty view. Read-only; used by agent-state detection.
    func surfaceViewportText(_ surfaceID: UUID) -> String? {
        ghosttyView(surfaceID)?.readViewportText()
    }

    /// OSC window title of a live terminal surface, or nil if it has no live
    /// Ghostty view. Read-only; used by agent-state detection.
    private func surfaceOSCTitle(_ surfaceID: UUID) -> String? {
        ghosttyView(surfaceID)?.readOSCTitle()
    }

    /// Latest OSC 9;4 progress state of a live terminal surface, or nil if it has
    /// no live Ghostty view. Read-only; used by agent-state detection.
    private func surfaceProgressReport(_ surfaceID: UUID) -> AgentProgressState? {
        ghosttyView(surfaceID)?.readProgressReport()
    }

    /// The persistent coordinator (and its `WKWebView`) for a browser surface,
    /// created on first use and loaded with the surface's URL. Cached by
    /// `Surface.id` so navigation state and the web view survive layout churn.
    func browserCoordinator(for surface: Surface) -> BrowserCoordinator? {
        guard case .browser(let url) = surface.kind else { return nil }
        if let existing = browserCoordinators[surface.id] { return existing }
        let coordinator = BrowserCoordinator(url: url)
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

    /// Select the inspector's active tab, expanding the panel if it was collapsed.
    func setInspectorTab(_ tab: InspectorTab, for workspaceID: UUID) {
        let mutated = mutate(workspaceID) {
            $0.inspector.tab = tab
            $0.inspector.collapsed = false
        }
        guard mutated else { return }
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
        guard mutate(workspaceID, { $0.inspector.collapsed = collapsed }) else { return }
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
        guard mutate(workspaceID, { $0.lastUsedEditor = kind }) else { return }
        persist()
    }

    /// The workspace's named commands (`.casper.json`, non-reserved, sorted).
    /// A pure cache read: a workspace whose commands have never been loaded reads
    /// as empty rather than touching the disk, so this is safe to call from a
    /// SwiftUI `body`. Loading is the job of `prewarmNamedCommands(for:)` and the
    /// selection/filesystem refreshes.
    func namedCommands(for workspaceID: UUID) -> [RepoNamedCommand] {
        namedCommandsCache[workspaceID] ?? []
    }

    /// Load a workspace's named commands unless they are already cached, so a view
    /// that will render them (a sidebar row's context menu) can pay the
    /// `.casper.json` read outside its `body`.
    func prewarmNamedCommands(for workspaceID: UUID) {
        guard namedCommandsCache[workspaceID] == nil else { return }
        refreshNamedCommands(for: workspaceID)
    }

    private func loadNamedCommands(for workspaceID: UUID) -> [RepoNamedCommand] {
        guard let ws = workspace(id: workspaceID),
              let config = (try? RepoConfig.load(fromRepoRoot: ws.worktreePath)) ?? nil
        else { return [] }
        return config.namedCommands()
    }

    /// Re-read a workspace's named commands (e.g. after it becomes selected).
    private func refreshNamedCommands(for workspaceID: UUID) {
        guard let ws = workspace(id: workspaceID) else { return }
        namedCommandsStamps[workspaceID] = configFileStamp(inWorktree: ws.worktreePath)
        namedCommandsCache[workspaceID] = loadNamedCommands(for: workspaceID)
    }

    /// Re-read a workspace's named commands from `.casper.json` in reaction to a
    /// filesystem change, updating the cache and bumping `scriptsRevision` only
    /// when the list actually changed. Idempotent on an unchanged file: the
    /// watcher has no `IgnoreSelf`, so Casper's own writes into the worktree also
    /// wake it, and an unchanged file must not churn the UI. A broken or missing
    /// file yields an empty list (same tolerance as `loadNamedCommands`).
    ///
    /// The modification date is checked first, so the common case — a build writing
    /// into the worktree, which fires this once per 200 ms debounce window for as long
    /// as it runs — costs one `stat` instead of a read and a JSON decode.
    func refreshNamedCommandsIfChanged(for workspaceID: UUID) {
        guard let ws = workspace(id: workspaceID) else { return }
        let stamp = configFileStamp(inWorktree: ws.worktreePath)
        guard stamp != namedCommandsStamps[workspaceID] else { return }
        namedCommandsStamps[workspaceID] = stamp
        let fresh = loadNamedCommands(for: workspaceID)
        guard fresh != namedCommandsCache[workspaceID] else { return }
        namedCommandsCache[workspaceID] = fresh
        scriptsRevision += 1
    }

    /// The modification date of `<worktreePath>/.casper.json`, or `.distantPast` when
    /// there is no readable file there — "absent" is as much an answer as a date, and
    /// keeping it non-optional means a workspace with no config still compares equal to
    /// itself from one filesystem event to the next.
    private func configFileStamp(inWorktree worktreePath: String) -> Date {
        let path = URL(fileURLWithPath: worktreePath).appendingPathComponent(".casper.json").path
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return attributes?[.modificationDate] as? Date ?? .distantPast
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
        guard mutate(workspaceID, { $0.lastUsedScript = name }) else { return }
        persist()
    }

    /// Run a named command in a visible terminal and remember it. On failure,
    /// sets `scriptRunError` (surfaced by an alert).
    func runScript(_ name: String, for workspaceID: UUID) {
        switch controlRun(name: name, in: workspaceID) {
        case .success:
            mutate(workspaceID) { $0.lastUsedScript = name }
            scriptRunError = nil
            persist()
        case .failure(let error):
            scriptRunError = error.message
        }
    }

    /// Publishes what the window's floor is built from, or `nil` once no workspace is
    /// on screen — which drops the floor rather than stranding the last workspace's
    /// one over an empty window.
    func setTerminalHostMetrics(_ metrics: TerminalHostMetrics?) {
        terminalHostMetrics = metrics
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

    // Reached from AppModel+Spaces.swift.
    /// Drop cached views and browser coordinators for the given surface ids
    /// (their PTYs or `WKWebView`s are freed on deinit).
    func discardSurfaceViews(_ ids: [UUID]) {
        for id in ids {
            // A background-nursery-hosted view is retained by the nursery's content view;
            // detach it so niling the cache actually frees the PTY. (A view that was later
            // selected lives in a real container and is torn down by SwiftUI.)
            if let nursery = backgroundSurfaceNursery, let view = surfaceViews[id], view.window === nursery {
                view.removeFromSuperview()
            }
            // Free the libghostty surface while its view is still fully alive: dropping
            // the reference alone frees the surface after `deinit`, when a libghostty
            // callback recovering the view from the per-surface userdata would resurrect
            // an object that is already deallocating.
            ghosttyView(id)?.invalidate()
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
                Session(spaces: spaces, selectedWorkspaceID: selectedWorkspaceID,
                        dismissedAgentReminders: agentReminders.dismissed,
                        lastNewSpaceLocation: lastNewSpaceLocation))
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

    // Reached from AppModel+Control.swift.
    /// Debounced persistence for high-frequency agent-state changes.
    func scheduleSave() {
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
        config.environment = AgentEnvironment.surfaceEnvironment(
            workspaceId: workspace.id,
            // Only linked worktrees need an offset port block; the primary working
            // tree keeps the project's default ports. The rule is kind-based, not
            // branch-name-based — a primary tree may sit on any branch.
            portBase: workspace.kind == .primary ? nil : workspace.portBase,
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
    /// state; returns nil for a non-Git folder (accepted by the UI-1 design — see
    /// `.superpowers/themes/app-ui.md` § Sub-projects).
    /// Uses `Repository.open`, an exact-path open, rather than `discover`,
    /// which walks up to parent directories — a Space must root at the
    /// folder the user picked, not at an ancestor repository.
    static func gitProbe(_ url: URL) -> WorkspaceFactory.GitInfo? {
        guard let repo = try? Repository.open(atPath: url.path),
              let workdir = repo.workdirPath else { return nil }
        let branch = (try? repo.headBranchName()) ?? ""
        let remote = (try? repo.remoteURL(named: "origin")) ?? nil
        let mainWorkingTree = repo.mainWorkingTree()
        return WorkspaceFactory.GitInfo(
            canonicalPath: standardizedPath(workdir),
            branch: branch, remoteURL: remote,
            // Canonicalized (not just standardized) because it is compared across
            // folders reached by different spellings — see `spacesSharingRepository`.
            commonDirPath: canonicalPath(repo.commonDirPath),
            isLinkedWorktree: repo.isLinkedWorktree,
            // Standardized like `canonicalPath` and for the same reason: on the main
            // working tree the two name that one folder, so they must normalize alike.
            mainWorkingTreePath: mainWorkingTree?.path.map(standardizedPath),
            isBareRepository: mainWorkingTree?.isBare ?? false)
    }

    /// `path` with `.`, `..` and a trailing slash resolved away, symlinks left alone.
    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Error carrying a human-readable reason for a failed workspace creation.
    struct WorkspaceCreationError: Error {
        let message: String
    }

    /// Error carrying a human-readable reason for a rejected `diff open` request.
    struct DiffOpenError: Error {
        let message: String
    }

    /// Error carrying a human-readable reason for a rejected `workspace delete`.
    struct WorkspaceDeleteError: Error {
        let message: String
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
    /// ticks to keep this main-actor pass cheap. The pass also re-probes the agent
    /// integrations once their last result has gone stale — see
    /// `refreshAgentIntegrationsIfStale`.
    func runAgentDetectionTick() {
        detectionTickCount &+= 1
        // Piggybacked on this loop rather than given a timer of its own. The reminder has
        // to retire itself while the user watches — the integration is installed by a
        // command typed in a Casper terminal, which never resigns the app active — and
        // this costs one `Date` comparison until the result actually goes stale.
        refreshAgentIntegrationsIfStale()
        let scrapeBackground = detectionTickCount % Self.backgroundDetectionStride == 0
        // Indexed so a detected change can be written straight at its workspace instead
        // of re-scanning every Space to find it again. Safe to hold across the body: a
        // detection pass only ever writes a workspace's transient state and expands a
        // collapsed Space — it never adds or removes one.
        for (si, space) in spaces.enumerated() {
            for (wi, ws) in space.workspaces.enumerated() {
                if explicitAuthority.contains(ws.id) { continue }  // detection stopped for W
                let isSelected = (ws.id == selectedWorkspaceID)
                if !isSelected && !scrapeBackground { continue }  // background: reduced sub-cadence

                // Collect the ids through `forEachSurface`: `surfaces(_:)` would build a
                // throwaway array of full `Surface` values, for every workspace, 4× a second.
                var terminalIDs: [UUID] = []
                LayoutTree.forEachSurface(ws.layout) { surface in
                    guard case .terminal = surface.kind else { return }
                    terminalIDs.append(surface.id)
                }
                let signals = terminalIDs.compactMap { id -> AgentSignal? in
                    guard let text = surfaceViewportText(id) else { return nil }  // no live view ⇒ skip
                    let oscTitle = surfaceOSCTitle(id)
                    // Every rule set is applied, because nothing here knows which agent runs
                    // in this surface. The two text sources are read once above and replayed
                    // across the rule sets — re-fetching them per rule set would triple the
                    // cost of the pass for no gain.
                    var textual = AgentSignal.absent
                    for rules in AgentDetectionRuleSet.all {
                        textual = max(textual, rules.signal(fromViewport: text))
                        if let oscTitle {
                            textual = max(textual, rules.signal(fromTitle: oscTitle))
                        }
                    }
                    let progress = surfaceProgressReport(id).map(AgentSignal.init(progress:)) ?? .absent
                    // Roll the sources together. The OSC 9;4 progress report is the primary
                    // "working" signal — Claude Code brackets a turn with `ESC]9;4;3` …
                    // `ESC]9;4;0`. The title spinner is a secondary one: still emitted, but its
                    // glyph set moved between releases, and only Claude Code has a title
                    // convention at all. The viewport carries "blocked", and is the only
                    // "working" source for an agent that reports no progress (Codex, opencode).
                    // The existing blocked > working > idle > absent precedence handles them
                    // all correctly, so the resolver needs no change.
                    return max(textual, progress)
                }
                if signals.isEmpty { continue }  // nothing readable ⇒ leave W's state untouched

                let aggregated = AgentSignal.aggregate(signals)
                let seen = (selectedWorkspaceID == ws.id)
                var resolver = agentResolvers[ws.id] ?? AgentStateResolver()
                let state = resolver.resolve(signal: aggregated, seen: seen)
                agentResolvers[ws.id] = resolver  // persist the mutated resolver back
                setDetectedAgentState(state, at: (space: si, workspace: wi))
            }
        }
    }

    /// Write a *detected* agent state. Distinct from the explicit
    /// `controlSetAgentState`: it must NOT grant authority. Writes only when the
    /// value actually changes, so a steady detection stream doesn't thrash the UI.
    /// Internal, not private, because `scriptHooks`' `reportSetupFailure` closure calls
    /// it from outside this file to flag a workspace whose `setup` hook failed.
    func setDetectedAgentState(_ state: AgentState, for workspaceID: UUID) {
        guard let at = locate(workspaceID) else { return }
        setDetectedAgentState(state, at: at)
    }

    /// The core of `setDetectedAgentState`, for a caller that has already resolved the
    /// workspace: `runAgentDetectionTick` walks `spaces` itself, so re-locating each
    /// workspace by id would rescan every Space once per detected change.
    private func setDetectedAgentState(_ state: AgentState, at: WorkspaceIndex) {
        let previous = workspace(at: at).agentState
        guard previous != state else { return }
        // agentState is transient (deliberately not encoded by Session's Codable),
        // so the @Observable mutation refreshes the sidebar with no need to persist.
        updateWorkspace(at: at) { $0.agentState = state }
        clearNotificationOnResume(from: previous, to: state, at: at)
        // A detected transition into an attention state raises the same notification
        // `casper notify` would — a real macOS notification plus the sidebar dot — so
        // the user is alerted without installing any agent hook. Reached only on an
        // actual change thanks to the guard above (edge-triggered, no extra dedup).
        if let message = Self.notificationMessage(for: state) {
            controlRaiseNotification(message: message, for: workspace(at: at).id)
        }
    }

    // Reached from AppModel+Control.swift.
    /// On a `done → working` resume, clear the stale "Done" notification entirely:
    /// both the caption (`pendingNotificationMessage`) and the LED
    /// (`pendingNotification`), so the sidebar bubble goes away once the agent picks
    /// the task back up. A no-op for any other transition.
    func clearNotificationOnResume(
        from previous: AgentState, to state: AgentState, at: WorkspaceIndex) {
        guard previous == .done, state == .working else { return }
        updateWorkspace(at: at) {
            $0.pendingNotificationMessage = nil
            $0.pendingNotification = false
        }
        refreshDockAttention()
    }

    // Reached from AppModel+Control.swift.
    /// The notification text for a detected state, or `nil` when the state needs
    /// no attention. Only `blocked` and `done` alert the user; the rest are silent.
    /// Exhaustive by design so a new `AgentState` case forces a decision here.
    static func notificationMessage(for state: AgentState) -> String? {
        switch state {
        case .blocked: return "Waiting for your input"
        case .done: return "Done"
        case .error: return "Something went wrong"
        case .working, .idle, .unknown: return nil
        }
    }

    // Reached from AppModel+Control.swift.
    /// The interruption level for a notification raised from a given state. `done`
    /// is informational — the user finished task arrives quietly in Notification
    /// Center (`.passive`: no banner, no sound). Every state that reaches delivery
    /// with a message (`blocked`, `error`) requires action, so it interrupts
    /// (`.active`: banner + sound). States that never notify still map to `.active`
    /// as a harmless default; only `done` needs the quieter treatment.
    static func interruptionLevel(for state: AgentState) -> UNNotificationInterruptionLevel {
        state == .done ? .passive : .active
    }

    // MARK: - Agent-integration reminders

    /// The dismissal ids the loaded session carried. Held as a plain `let` because the
    /// controller below is lazy — it cannot be built from `init`, where `self` is not
    /// yet whole enough to capture in its `persist` closure — and this is the one piece
    /// of its state that only `init` knows.
    @ObservationIgnored private let restoredAgentReminderDismissals: Set<String>

    /// The sidebar's coding-agent integration reminders: the probe cadence, the
    /// dismissals, and the published lines. `AppModel` keeps only the forwarding
    /// surface below, which is what the sidebar views and the tests address.
    ///
    /// Lazy so the injected `persist` can capture a fully-initialized `self`, which it
    /// captures WEAKLY — this model owns the controller, and a strong capture would
    /// close the retain cycle. Same shape as `scriptHooks` and `browserAutomation`.
    @ObservationIgnored private(set) lazy var agentReminders = AgentIntegrationReminders(
        dismissed: restoredAgentReminderDismissals,
        persist: { [weak self] in self?.persist() })

    /// One sidebar reminder line. Spelled `AppModel.AgentIntegrationReminder` by the
    /// views and the tests, so the name stays put now that the type lives in its own file.
    typealias AgentIntegrationReminder = AgentIntegrationReminders.Reminder

    /// How long a probe result stays fresh before a stale check re-runs one.
    nonisolated static var agentIntegrationProbeInterval: TimeInterval {
        AgentIntegrationReminders.probeInterval
    }

    /// Whether a stale check should re-probe.
    nonisolated static func shouldRefreshAgentIntegrations(lastProbeAt: Date?, now: Date) -> Bool {
        AgentIntegrationReminders.shouldRefresh(lastProbeAt: lastProbeAt, now: now)
    }

    /// Probes each agent's integration. Injectable so tests never spawn a login shell
    /// or read the real home directory.
    var agentIntegrationProbe: @Sendable () -> [CodingAgent: AgentIntegrationStatus] {
        get { agentReminders.probe }
        set { agentReminders.probe = newValue }
    }

    /// The agents the sidebar should currently remind about, in `CodingAgent.allCases`
    /// order. Observed through `agentReminders`, so a probe landing after the sidebar
    /// has rendered still re-renders it.
    var agentIntegrationReminders: [AgentIntegrationReminder] { agentReminders.reminders }

    /// The in-flight probe, if any — the seam a test awaits after triggering one.
    var agentIntegrationTask: Task<Void, Never>? { agentReminders.task }

    /// Probe now, whatever the last result's age (the launch probe).
    func refreshAgentIntegrations() { agentReminders.refresh() }

    /// Re-probe if the last result is older than `agentIntegrationProbeInterval`.
    func refreshAgentIntegrationsIfStale() { agentReminders.refreshIfStale() }

    /// The user opened a reminder's documentation, so an install is imminent.
    func agentReminderDocumentationOpened() { agentReminders.documentationOpened() }

    /// Dismiss one reminder line, permanently as far as this problem is concerned.
    func dismissAgentReminder(_ reminder: AgentIntegrationReminder) {
        agentReminders.dismiss(reminder)
    }

    // MARK: - `.casper.json` lifecycle hooks

    // Reached from AppModel+Spaces.swift and AppModel+Control.swift.
    /// The `setup`/`teardown` hook machinery: the visible hook splits, the child-exit
    /// correlation, and the once-latched teardown prune. Lazy so the injected closures
    /// can capture a fully-initialized `self`; all three capture it WEAKLY, because
    /// this model owns the runner and a strong capture would close the retain cycle.
    @ObservationIgnored lazy var scriptHooks = ScriptHookRunner(
        // Hook splits are plain terminal splits stacked below the anchor; the hook
        // policy stays in the runner, which owns the surface's identity.
        insertSurface: { [weak self] workspaceID, surface, command in
            self?.insertTerminal(surface, in: workspaceID, command: command, orientation: .vertical)
                ?? false
        },
        worktreePath: { [weak self] id in self?.workspace(id: id)?.worktreePath },
        reportSetupFailure: { [weak self] id in self?.setDetectedAgentState(.error, for: id) })

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
}
