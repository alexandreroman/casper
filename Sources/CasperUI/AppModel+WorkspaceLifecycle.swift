import CasperCore
import Foundation

/// The workspace close/delete lifecycle: the off-main-actor git hop, the progress
/// reporter, and the merge-then-prune and prune-only flows behind the sidebar
/// actions and the control channel's delete verb. Part of `AppModel`.
extension AppModel {
    // Reached from AppModel.swift.
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
    static func offloadGit<T: Sendable>(
        _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: body).value
    }

    /// Whether the worktree at `path` has no uncommitted changes, probed off the main
    /// actor through `offloadGit` like every other git call on the close/delete path —
    /// a full libgit2 status scan on a large worktree stalls the main thread for long
    /// enough to be seen (and to trip the DEBUG hang watchdog).
    ///
    /// Fails safe toward "not clean": a thrown probe error reads the same as a genuinely
    /// dirty tree, so a failure can never silently hide the destructive-delete warning
    /// that depends on this.
    func isWorktreeClean(_ path: String) async -> Bool {
        let clean = try? await Self.offloadGit { try WorktreeManager.isClean(repoPath: path) }
        return clean ?? false
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
