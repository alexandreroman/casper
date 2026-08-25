import AppKit
import CasperCore
import Foundation

// MARK: - AppKit presentation layer

/// The AppKit-facing side of `AppModel`: the modal panels, alerts and user
/// notifications the app puts on screen, plus the model calls they trigger on
/// confirmation. The dialogs themselves are built by `WorkspaceAlerts` below, so the
/// methods here stay readable as orchestration.
extension AppModel {
    /// Open a directory picker and adopt the chosen folder as a workspace, reporting
    /// a folder that could not be added. `addSpace` runs no modal of its own — it is
    /// also driven headlessly — so the alert belongs here.
    func presentAddFolderPanel() {
        guard let url = WorkspaceAlerts.chooseFolder() else { return }
        if case .failed(let reason) = addSpace(folderURL: url, probe: Self.gitProbe) {
            WorkspaceAlerts.reportAddFolderFailure(folder: url.lastPathComponent, reason: reason)
        }
    }

    /// Prompt for a linked-workspace name and create it. AppKit alert with a text
    /// field; no-op on cancel or empty input.
    ///
    /// The prompt itself stays modal; only the creation that follows it is async (the
    /// worktree checkout runs off the main actor), so the sidebar's call site keeps its
    /// plain signature.
    func presentAddLinkedWorkspacePanel(spaceID: UUID) {
        guard let name = WorkspaceAlerts.askWorkspaceName() else { return }
        Task { @MainActor in
            let created = await self.addLinkedWorkspace(spaceID: spaceID, name: name)
            if !created { WorkspaceAlerts.reportCreationFailure(name: name) }
        }
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
        guard WorkspaceAlerts.confirmMergeAndClose(name: ws.name, branch: ws.branch, baseBranch: baseBranch)
        else { return }
        // The confirmation itself stays modal (`confirmMergeAndClose` runs it); only the
        // work that follows it is async, so the sidebar's call site keeps its plain
        // signature.
        Task { @MainActor in
            let outcome = await self.closeWorkspace(id: workspaceID) { status in
                self.reportTeardownHookFailure(status, workspace: ws.name, id: workspaceID, verb: "closed")
            }
            switch outcome {
            case .success:
                break
            case .mergeFailed(let message):
                await self.presentWorkspaceOperationFailureAlert(
                    for: workspaceID, title: "Could not close \u{201c}\(ws.name)\u{201d}",
                    message: message)
            case .cleanupFailed(let message):
                await self.presentWorkspaceOperationFailureAlert(
                    for: workspaceID,
                    title: "\u{201c}\(ws.name)\u{201d} merged but not fully cleaned up",
                    message: message)
            }
        }
    }

    /// A confirmation, then `deleteWorkspace(id:)` on confirm. Unlike
    /// `closeWorkspace`, this never merges, so uncommitted changes in `ws`
    /// really are discarded — the warning below stays. Same HIG-correct
    /// default-button treatment as `presentCloseWorkspaceConfirmation`.
    func presentDeleteWorkspaceConfirmation(id workspaceID: UUID) {
        guard let ws = workspace(id: workspaceID) else { return }
        // The whole body runs in a Task because the cleanliness probe is off-actor
        // (`isWorktreeClean`): the alert must not be entered until it has returned, or
        // `runModal` would park the main thread with the probe still in flight.
        Task { @MainActor in
            let clean = await self.isWorktreeClean(ws.worktreePath)
            guard WorkspaceAlerts.confirmDelete(name: ws.name, branch: ws.branch, dirty: !clean)
            else { return }
            let result = await self.deleteWorkspace(id: workspaceID) { status in
                self.reportTeardownHookFailure(status, workspace: ws.name, id: workspaceID, verb: "deleted")
            }
            if case .failure(let error) = result {
                await self.presentWorkspaceOperationFailureAlert(
                    for: workspaceID, title: "Could not delete \u{201c}\(ws.name)\u{201d}",
                    message: error.message)
            }
        }
    }

    /// Notify the user that a workspace's `teardown` hook did not end well. The workspace
    /// is closed or deleted regardless — a broken teardown never blocks deletion — so this
    /// notification is the only place the failure surfaces outside the log. `verb` is what
    /// just happened to the workspace: "closed" or "deleted".
    ///
    /// `.active` rather than `.passive`: a passive notification is a silent Notification
    /// Center entry, which the user would simply never see.
    ///
    /// `.couldNotSpawn` stays log-only, alongside `.none` and `.succeeded`. It means
    /// Casper failed to create the teardown split — an internal failure, not the user's
    /// script failing — so there is nothing actionable to report.
    ///
    /// Internal rather than private only so tests can exercise it: its two callers are
    /// the confirmation presenters above, which run an `NSAlert` modally and therefore
    /// cannot be driven headlessly.
    func reportTeardownHookFailure(
        _ status: TeardownHookStatus, workspace name: String, id workspaceID: UUID, verb: String
    ) {
        let title: String
        let cause: String
        switch status {
        case .failed(let exitCode):
            title = "Teardown hook failed"
            cause = "failed (exit \(exitCode))"
        case .timedOut:
            title = "Teardown hook timed out"
            cause = "timed out after \(Int(ScriptHookRunner.teardownTimeout))s"
        case .none, .succeeded, .couldNotSpawn:
            return
        }
        deliverNotification(
            title, "\u{201c}\(name)\u{201d} \(verb), but its teardown hook \(cause)",
            workspaceID, .active)
    }

    /// A generic error alert for a failed close/delete operation on `workspaceID`.
    ///
    /// Silent when the workspace is already gone: the only way to reach here in that
    /// state is an operation the user effectively cancelled by discarding the workspace
    /// (or its whole Space) mid-flight, and the precise error it produced — "workspace
    /// not found" — describes exactly the outcome they asked for. The error itself is
    /// untouched, so the control channel and the tests still see it.
    ///
    /// Async because of the hop below: the progress sheet is dismissed by clearing
    /// `closeProgress`, but SwiftUI only tears it down on a later turn of the run loop,
    /// and an `NSAlert` run modally before that stacks on top of a live sheet. Clearing
    /// here too (the orchestrator already did on its way out) keeps that invariant local
    /// to the one place that runs a modal — and, exactly like the reporter, only clears a
    /// sheet that belongs to this operation.
    ///
    /// The hop goes through `MainRunLoop`, not the main queue: a close that fails while
    /// any other panel is up (Add Folder…, Create Workspace…, a Sparkle update check)
    /// would otherwise hold this alert back for that panel's whole lifetime.
    private func presentWorkspaceOperationFailureAlert(
        for workspaceID: UUID, title: String, message: String
    ) async {
        if closeProgress?.id == workspaceID { closeProgress = nil }
        guard workspace(id: workspaceID) != nil else { return }
        await withCheckedContinuation { continuation in
            MainRunLoop.perform { continuation.resume() }
        }
        WorkspaceAlerts.reportFailure(title: title, message: message)
    }
}

// MARK: - Dialog construction

/// Raw AppKit dialog assembly for the workspace flows above: every panel and
/// alert is built and run here, so each call site reads as a single question
/// with a plain Swift answer.
@MainActor
private enum WorkspaceAlerts {
    /// Directory picker for adopting a folder as a Space. Nil on cancel.
    static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }

    /// Name prompt for a new linked workspace. Nil on cancel or empty input.
    static func askWorkspaceName() -> String? {
        let alert = NSAlert()
        alert.messageText = "Create Workspace"
        alert.informativeText = "Name for the new branch and worktree:"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return name
    }

    /// Report a folder the user picked that Casper could not add.
    static func reportAddFolderFailure(
        folder: String, reason: AppModel.AddSpaceOutcome.Failure
    ) {
        let message: String
        switch reason {
        case .bareRepository:
            message = "This folder is a worktree of a bare repository. Casper opens a "
                + "repository at its main working tree, which a bare repository does not "
                + "have, so it does not support this layout."
        case .mainWorkingTreeUnresolved:
            message = "This folder is a Git worktree, but Casper could not resolve its "
                + "repository\u{2019}s main working tree, so it has no folder to open the "
                + "repository at."
        case .noFreePortBlock:
            message = "Casper has no free port block left to give a new workspace."
        }
        reportFailure(title: "Could not add \u{201c}\(folder)\u{201d}", message: message)
    }

    static func reportCreationFailure(name: String) {
        let alert = NSAlert()
        alert.messageText = "Could not create workspace"
        alert.informativeText =
            "\u{201c}\(name)\u{201d} could not be created. A branch or worktree with that name "
            + "may already exist, or the name is not a valid branch name."
        alert.runModal()
    }

    /// True when the user confirms the merge-and-close.
    static func confirmMergeAndClose(name: String, branch: String, baseBranch: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Merge and Close \u{201c}\(name)\u{201d}?"
        alert.informativeText = "This merges branch \u{201c}\(branch)\u{201d} into "
            + "\u{201c}\(baseBranch)\u{201d}, then deletes the worktree and its folder on disk. "
            + "This can\u{2019}t be undone."
        let mergeButton = alert.addButton(withTitle: "Merge and Close")
        alert.addButton(withTitle: "Cancel")
        mergeButton.hasDestructiveAction = true
        mergeButton.keyEquivalent = ""
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// True when the user confirms the delete.
    static func confirmDelete(name: String, branch: String, dirty: Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Delete \u{201c}\(name)\u{201d}?"
        var text = "This deletes the worktree, its folder on disk, and branch "
            + "\u{201c}\(branch)\u{201d} without merging. This can\u{2019}t be undone."
        if dirty { text += " This workspace has uncommitted changes that will be lost." }
        alert.informativeText = text
        let deleteButton = alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        deleteButton.hasDestructiveAction = true
        deleteButton.keyEquivalent = ""
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func reportFailure(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
