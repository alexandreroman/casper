import AppKit
import CasperCore
import Foundation

/// The `.casper.json` lifecycle-hook machinery: it spawns the visible `setup` /
/// `teardown` splits, correlates each hook's child-exit with the pane close
/// libghostty delivers for it afterwards, and reports how a `teardown` ended to the
/// destroy that is awaiting it.
///
/// Every correctness argument here rests on libghostty delivering the child-exit
/// action SYNCHRONOUSLY mid-`ghostty_app_tick` while `close_surface_cb` DEFERS its
/// close to the next runloop turn — so `handleScriptSurfaceExit` always runs BEFORE
/// the correlated pane close. Nothing is ever closed or pruned eagerly inside a
/// child-exit callback (see `finishTeardown`).
///
/// The enforcement boundary moved with the split-out: `runSetupHook` and `runTeardown`
/// are module-internal, so what keeps a lifecycle hook from being started by hand is no
/// longer their access level but the fact that the only instance of this runner is
/// `AppModel`'s `private` `scriptHooks` property. (Before the split-out, `private` on
/// `spawnScriptSurface` enforced that mechanically.)
///
/// What deliberately does NOT live here is `AppModel.closingWorkspaces`, the claim that
/// rejects a re-entrant destroy: it covers the whole close/delete operation —
/// cleanliness probes, merge, prune — of which the hook is only one step.
///
/// Deliberately knows nothing about `AppModel`: the three things it needs — spawning
/// a hook terminal, resolving a workspace's worktree path, and reporting a failed
/// setup — are injected as closures, the same test-seam idiom `AppModel` uses for
/// `makeWorktreeWatcher` / `deliverNotification` / `gitReprobe`.
@MainActor
final class ScriptHookRunner {
    enum ScriptHookKind { case setup, teardown }

    /// How a workspace's `teardown` lifecycle hook ended. A failure never blocks the
    /// destroy — the caller prunes regardless — so this is reported, not acted upon.
    enum TeardownHookStatus: Equatable, Sendable {
        /// No hook configured for this workspace.
        case none
        case succeeded
        case failed(exitCode: Int32)
        case timedOut
        /// The teardown split itself could not be created (an internal failure, not
        /// the user's script failing).
        case couldNotSpawn
    }

    /// A terminal split running a lifecycle hook (`setup`/`teardown`). Tracked so the
    /// child-exit event can be correlated with the pane's close request.
    private struct ScriptSurface {
        let kind: ScriptHookKind
        let workspaceID: UUID
        /// Teardown completion (delivers the exit code, or is called on timeout by the
        /// runner); nil for setup.
        var onExit: ((Int32) -> Void)?
    }

    /// One workspace's in-flight teardown hook: the resume of the `runTeardown`
    /// continuation awaiting its outcome, plus the run's generation.
    ///
    /// The generation is what lets a trigger identify itself as stale. The 30 s
    /// timeout is scheduled once per run and cannot be un-scheduled; without a
    /// generation its only guard would be "some teardown is in flight for this
    /// workspace id", so the timer of a run that already ended (a close that failed
    /// at the prune step, say) would happily time out the user's *retry* seconds
    /// after it started. The child-exit callback of an abandoned split has the same
    /// shape, so it carries a generation too.
    private struct PendingTeardown {
        let generation: UInt64
        let resume: @MainActor (TeardownHookStatus) -> Void
    }

    /// How long a `teardown` hook may run before the workspace is pruned anyway. A
    /// broken cleanup script must never trap the user in the workspace.
    static let teardownTimeout: TimeInterval = 30

    private let insertSurface: (UUID, Surface, String) -> Bool
    private let worktreePath: (UUID) -> String?
    private let reportSetupFailure: (UUID) -> Void

    private var scriptSurfaces: [UUID: ScriptSurface] = [:]
    /// Surfaces of a FAILED setup whose one shell-exit-driven close must be swallowed
    /// so the pane stays open showing the error output.
    private var keptFailedSetupSurfaces: Set<UUID> = []

    /// Workspaces whose teardown hook is in flight, keyed by workspace id. Presence is
    /// the once-latch: every exit path (child exit, manual split close, timeout, spawn
    /// failure, workspace dropped) check-and-removes the id through `finishTeardown`, so
    /// the continuation is resumed exactly once — whichever arrives first wins, and
    /// `withCheckedContinuation` never sees the double resume it traps on.
    /// Main-actor-isolated, so the check-and-remove needs no other synchronization.
    /// Transient, never persisted.
    private var pendingTeardownResumes: [UUID: PendingTeardown] = [:]

    /// Source of the per-run generation above. Monotonic for the process lifetime.
    private var lastTeardownGeneration: UInt64 = 0

    /// - Parameters:
    ///   - insertSurface: Insert the given surface into a workspace as a split-down
    ///     terminal running the given (already hook-wrapped) command; false when the
    ///     workspace or its anchor can't be resolved.
    ///   - worktreePath: A workspace's worktree path, used as the hook split's working
    ///     directory; nil when the workspace no longer exists.
    ///   - reportSetupFailure: Flag a workspace whose `setup` hook exited non-zero.
    init(
        insertSurface: @escaping (UUID, Surface, String) -> Bool,
        worktreePath: @escaping (UUID) -> String?,
        reportSetupFailure: @escaping (UUID) -> Void
    ) {
        self.insertSurface = insertSurface
        self.worktreePath = worktreePath
        self.reportSetupFailure = reportSetupFailure
    }

    // MARK: - Running the hooks

    /// Run a workspace's `setup` lifecycle hook in a visible split. Together with
    /// `runTeardown` the only hook spawn exposed to callers: `spawnScriptSurface`
    /// itself stays private, so a hook can never be started by hand.
    func runSetupHook(in workspaceID: UUID, command: String) {
        spawnScriptSurface(kind: .setup, in: workspaceID, command: command, onExit: nil)
    }

    /// Spawn a visible split-down (top/bottom stack) in `workspaceID` running a
    /// lifecycle hook, tagged in `scriptSurfaces` so its child-exit is correlated.
    /// Hook-wraps the command and registers the tag BEFORE splitting. Returns the
    /// new surface id, or nil if the workspace/anchor can't be resolved.
    @discardableResult
    private func spawnScriptSurface(
        kind: ScriptHookKind, in workspaceID: UUID, command: String,
        onExit: ((Int32) -> Void)?
    ) -> UUID? {
        guard let path = worktreePath(workspaceID) else { return nil }
        let surface = Surface.terminal(cwd: path)
        scriptSurfaces[surface.id] = ScriptSurface(kind: kind, workspaceID: workspaceID, onExit: onExit)
        guard insertSurface(workspaceID, surface, Self.hookWrappedScriptCommand(command)) else {
            // The split never happened, so no child-exit can ever clear the tag we
            // just wrote: drop it rather than leaking a tag for a surface that
            // doesn't exist (which would also block that id's close forever).
            scriptSurfaces[surface.id] = nil
            return nil
        }
        return surface.id
    }

    /// Called when a surface's child process exits (via GhosttySurfaceView.onChildExit).
    /// No-op for ordinary panes (not in `scriptSurfaces`).
    func handleScriptSurfaceExit(_ surfaceID: UUID, code: Int32) {
        guard let script = scriptSurfaces.removeValue(forKey: surfaceID) else { return }
        switch script.kind {
        case .setup:
            if code != 0 {
                // Failure: keep the pane open showing the output, swallow the single
                // shell-exit-driven close that follows (see keptFailedSetupSurfaces /
                // applyCloseSurface), and flag the workspace.
                keptFailedSetupSurfaces.insert(surfaceID)
                reportSetupFailure(script.workspaceID)
                CasperLog.app.error("setup script failed (exit \(code)); keeping the split open")
            }
            // On success there is nothing to do here: the tag is already cleared, so
            // the deferred close_surface_cb (fired by the shell's own exit) tears the
            // split down through the normal path. We must NOT close eagerly — this runs
            // synchronously inside libghostty's action_cb, and tearing views down
            // mid-tick is the sibling-detachment hazard that close_surface_cb defers.
        case .teardown:
            script.onExit?(code)
        }
    }

    /// Run the workspace's `teardown` lifecycle hook in a visible split and wait for it
    /// to finish. `command` is the already-resolved hook (see `AppModel.teardownCommand`);
    /// nil means there is no hook and the call returns `.none` without suspending, so a
    /// hookless destroy behaves exactly as it did before hooks existed. Otherwise the
    /// split is spawned and this returns when its child exits, when the user closes the
    /// split by hand, or when `teardownTimeout` elapses — whichever comes first. A
    /// non-zero exit or a timeout is logged and still returns normally: the caller
    /// prunes regardless, because a broken teardown must never block deletion.
    ///
    /// The caller always resumes on a later main-queue turn than the child-exit
    /// callback that ended the hook — see `finishTeardown` for why that matters.
    func runTeardown(id workspaceID: UUID, command: String?) async -> TeardownHookStatus {
        guard let command else { return .none }
        lastTeardownGeneration += 1
        let generation = lastTeardownGeneration
        return await withCheckedContinuation { continuation in
            // Arming must never clobber a live entry: the overwritten run's continuation
            // could then never be resumed (a permanently suspended caller, and the
            // "continuation leaked" trap). The whole operation is claimed in
            // `AppModel.closingWorkspaces`, so this is unreachable — hence the fault log
            // rather than a user-facing story.
            guard pendingTeardownResumes[workspaceID] == nil else {
                CasperLog.app.fault(
                    "teardown already in flight for this workspace; refusing to run a second one")
                continuation.resume(returning: .couldNotSpawn)
                return
            }
            // Arm the once-latch (its presence gates every exit path) before either trigger.
            pendingTeardownResumes[workspaceID] = PendingTeardown(
                generation: generation, resume: { continuation.resume(returning: $0) })
            guard spawnScriptSurface(
                kind: .teardown, in: workspaceID, command: command,
                onExit: { [weak self] code in
                    // Delivered synchronously inside ghostty_app_tick on the main actor; the
                    // resume it triggers is deferred off this callback (see finishTeardown).
                    MainActor.assumeIsolated {
                        guard let self, self.isTeardownCurrent(workspaceID, generation: generation)
                        else { return }
                        if code != 0 {
                            CasperLog.app.error("teardown script failed (exit \(code)); pruning anyway")
                        }
                        self.finishTeardown(
                            id: workspaceID, generation: generation,
                            status: code == 0 ? .succeeded : .failed(exitCode: code))
                    }
                }) != nil
            else {
                // Couldn't create the teardown split: return now rather than stalling
                // the caller until the timeout. Logged because the hook silently never
                // ran, and nothing else records that.
                CasperLog.app.error("teardown script could not be spawned; pruning anyway")
                finishTeardown(id: workspaceID, generation: generation, status: .couldNotSpawn)
                return
            }
            Self.onMainRunLoop(after: Self.teardownTimeout) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.isTeardownCurrent(workspaceID, generation: generation)
                    else { return }
                    CasperLog.app.error(
                        "teardown script timed out after \(Int(Self.teardownTimeout))s; pruning anyway")
                    self.finishTeardown(id: workspaceID, generation: generation, status: .timedOut)
                }
            }
        }
    }

    /// Resume a workspace's latched `runTeardown` continuation exactly once, on the
    /// NEXT main-queue turn. The child-exit path calls this from inside
    /// `ghostty_app_tick`, and the caller tears views down (prunes the workspace) as
    /// soon as it resumes — doing that mid-tick detaches sibling panes, the exact
    /// hazard `close_surface_cb` defers for. Resuming a continuation already enqueues
    /// the awaiting task rather than running it inline, but this hop makes the
    /// guarantee independent of that scheduling detail: the resume itself happens in a
    /// later main-queue work item, off the tick. A no-op once the latch has been
    /// cleared by another exit path, which is what keeps the resume exactly-once.
    ///
    /// `generation` scopes the resume to one specific run: a trigger left over from an
    /// earlier run for the same workspace id passes its own generation and is ignored.
    /// Callers that mean "whatever is in flight, end it" (the workspace being dropped
    /// outright) pass nil.
    private func finishTeardown(
        id workspaceID: UUID, generation: UInt64? = nil, status: TeardownHookStatus
    ) {
        guard let pending = pendingTeardownResumes[workspaceID],
              generation == nil || generation == pending.generation
        else { return }
        pendingTeardownResumes[workspaceID] = nil
        Self.onMainRunLoop { MainActor.assumeIsolated { pending.resume(status) } }
    }

    /// Run `body` on the main thread on a LATER turn of the main run loop.
    ///
    /// Deliberately not `DispatchQueue.main.async`: while the main thread sits in a
    /// nested run loop — which it does on this very actor whenever
    /// `AppModel+Presentation` runs an `NSAlert`/`NSOpenPanel` modally — libdispatch
    /// refuses to re-enter the main queue, so a main-queue block waits until the user
    /// dismisses the panel (the `main-queue-starved-by-modal-loops` note). A teardown
    /// that finished behind a panel would stall the close awaiting it, and the safety
    /// timeout below would be stalled with it, defeating the guarantee that a broken
    /// cleanup script never traps the user. Run-loop blocks carry no such re-entrancy
    /// guard: the nested loop drains them.
    ///
    /// The deferral off the current turn is load-bearing on the child-exit path (see
    /// `finishTeardown`) and survives the switch: `CFRunLoopPerformBlock` enqueues the
    /// block for a later pass of the loop, it never runs it inline.
    ///
    /// `nonisolated` because the whole point is to be callable from wherever the caller
    /// happens to be — the timeout below hands work over from a background queue. The
    /// three CoreFoundation calls are thread-safe by design; handing a block to another
    /// thread's run loop is exactly what they are for. `body` carries its own isolation:
    /// it is `@Sendable`, and the run loop drains it on the main thread.
    nonisolated private static func onMainRunLoop(_ body: @escaping @Sendable () -> Void) {
        let mainRunLoop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(mainRunLoop, runLoopModes, body)
        // A run loop asleep in `mach_msg` would sit on the block until its next event,
        // which on an idle app is however long the user takes to touch the app again.
        CFRunLoopWakeUp(mainRunLoop)
    }

    /// `onMainRunLoop`, delayed by `delay` seconds.
    ///
    /// The wait itself is measured on a background queue so that a modal panel standing
    /// when the deadline elapses cannot push it out — only the delivery hops back to the
    /// main thread, through the same modal-proof route.
    private static func onMainRunLoop(
        after delay: TimeInterval, _ body: @escaping @Sendable () -> Void
    ) {
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { onMainRunLoop(body) }
    }

    /// The run loop modes `onMainRunLoop` enqueues for: the common modes for ordinary
    /// event processing, plus the two nested loops AppKit spins on its own (modal
    /// sessions and menu/drag tracking). Built once and shared.
    ///
    /// `nonisolated(unsafe)` because `CFArray` is not `Sendable`, even though this one is
    /// immutable and never handed out.
    nonisolated(unsafe) private static let runLoopModes: CFArray = [
        CFRunLoopMode.commonModes.rawValue,
        RunLoop.Mode.modalPanel.rawValue as CFString,
        RunLoop.Mode.eventTracking.rawValue as CFString,
    ] as CFArray

    /// True while THIS teardown run is still the one in flight for `workspaceID` — i.e.
    /// its caller is still suspended and no later run has taken its place. What makes a
    /// stale timeout timer or an abandoned split's child exit identify itself as stale.
    private func isTeardownCurrent(_ workspaceID: UUID, generation: UInt64) -> Bool {
        pendingTeardownResumes[workspaceID]?.generation == generation
    }

    // MARK: - Queries for the pane-close path

    /// Whether `surfaceID` is a `setup` split whose child-exit has not been processed
    /// yet — such a surface must never be torn down by an early/stray close, since its
    /// fate is decided by `handleScriptSurfaceExit`.
    func isPendingSetupSurface(_ surfaceID: UUID) -> Bool {
        scriptSurfaces[surfaceID]?.kind == .setup
    }

    /// Consume the marker armed for a FAILED setup surface, returning whether one was
    /// present — in which case the caller must swallow this one close.
    func consumeKeptFailedSetup(_ surfaceID: UUID) -> Bool {
        keptFailedSetupSurfaces.remove(surfaceID) != nil
    }

    /// End a `teardown` split that is being closed while it still carries its tag — the
    /// user closed the pane before its child-exit was processed. Returns whether
    /// `surfaceID` was such a split, in which case the caller must swallow this close
    /// and let the resumed destroy's prune tear the whole workspace (this split
    /// included) down.
    ///
    /// A manual close carries no exit code, so this reports success rather than
    /// inventing a failure — and it reports it through the split's own `onExit`, which
    /// is what scopes the resume to the run that spawned it: the split of an abandoned
    /// run must not end a later run for the same workspace.
    func finishManuallyClosedTeardown(_ surfaceID: UUID) -> Bool {
        guard let script = scriptSurfaces[surfaceID], script.kind == .teardown else { return false }
        scriptSurfaces[surfaceID] = nil
        script.onExit?(0)
        return true
    }

    /// Drop every hook tag belonging to a workspace being removed outright, so a long
    /// session with workspace churn doesn't accumulate dead entries.
    func forget(surfaceIDs: [UUID], workspaceID: UUID) {
        // Teardown once-latch: the workspace is being dropped outright, so there is
        // nothing left for the destroy to prune — but the latch must never be cleared
        // without resuming, or the caller awaiting `runTeardown` would stay suspended
        // forever. The hook's real outcome is unknown here and the workspace is already
        // gone, so report success rather than inventing a failure.
        finishTeardown(id: workspaceID, status: .succeeded)
        // Per-surface setup-hook maps, so a workspace removed while its setup split
        // is live doesn't leak its surface entries.
        for surfaceID in surfaceIDs {
            scriptSurfaces[surfaceID] = nil
            keptFailedSetupSurfaces.remove(surfaceID)
        }
    }

    // MARK: - Command wrapping

    /// Wrap a `casper run` command in a subshell so a script that calls `exit`
    /// (or fails under `set -e`) terminates only the subshell, isolating it from
    /// the interactive shell. The trailing `[ $? -eq 0 ] && exit` then makes the
    /// interactive shell exit — closing the pane via the normal close path — only
    /// when the script succeeded (exit 0). A failing script (non-zero `$?`) leaves
    /// the interactive shell alive at a prompt with its output still visible. The
    /// command and the closing `[ … ]` test each sit on their own line so a
    /// trailing `#` comment cannot swallow the closing paren or the test.
    static func subshellWrappedScriptCommand(_ command: String) -> String {
        "(\n\(command)\n)\n[ $? -eq 0 ] && exit"
    }

    /// Wrap a lifecycle-hook command so the shell runs it and then exits with its
    /// status: `<command>\nexit $?`. The trailing `exit` makes libghostty emit a
    /// child-exit event carrying the status (the completion signal the hook needs) —
    /// the deliberate opposite of `subshellWrappedScriptCommand`, which keeps the
    /// pane open. The newline (not `; `) ensures a trailing `#` comment on the
    /// command's last line cannot swallow `exit $?`.
    static func hookWrappedScriptCommand(_ command: String) -> String {
        "\(command)\nexit $?"
    }
}
