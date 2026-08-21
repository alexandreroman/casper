import CasperCore
import Foundation
import SwiftUI

/// The `casper` control-channel handlers — agent state, progress, notifications,
/// info panel, terminals, browser and diff — and the `.casper.json` lifecycle-hook
/// bridge onto `ScriptHookRunner`. Part of `AppModel`.
extension AppModel {
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

    /// Test seam: whether `workspaceID` is under explicit (CLI) authority, which
    /// suppresses terminal-scraping detection for it. Production code reads
    /// `explicitAuthority` directly; only `AgentDetectionTests` calls this.
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

    // Reached from AppModel.swift and AppModel+Spaces.swift.
    /// Push the number of workspaces still carrying an attention bubble to the Dock
    /// badge, so the icon reads as an unread counter across every Space. Reaching zero
    /// also releases any outstanding bounce request: a badge-free Dock icon must never
    /// be left bouncing.
    ///
    /// Derived state only — it reads `spaces` and writes nothing, so calling it from a
    /// guarded path cannot introduce a spurious `persist()` or `@Observable` write.
    func refreshDockAttention() {
        let unread = spaces.reduce(0) { $0 + $1.workspaces.filter(\.pendingNotification).count }
        dockAttention.updateBadge(count: unread)
        if unread == 0 { dockAttention.cancelBounce() }
    }

    /// Release the Dock bounce request, without touching the badge.
    ///
    /// Called as Casper comes to the front — macOS has already stopped the bounce, and
    /// cancelling frees the request id so the next notification starts a fresh one —
    /// and again as it goes to the back, where a request made while it was active (one
    /// `bounce()` declined to make, but which a race could still have left behind)
    /// would be meaningless.
    ///
    /// The badge is deliberately left alone in both cases: it is an unread counter, and
    /// an unread clears only when its own workspace is dealt with, not merely because
    /// Casper changed places with another app.
    func releaseDockBounce() {
        dockAttention.cancelBounce()
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
        // Whether either branch below actually changed the model. Raising a
        // notification on a workspace that is both focused and already expanded writes
        // nothing, and that case is reached on every detected `blocked`/`done` edge and
        // every `casper notify` — so it must not encode the whole session and queue a
        // disk write for a state nobody changed.
        var wrote = false
        if !focused {
            updateWorkspace(at: at) {
                $0.pendingNotification = true
                $0.pendingNotificationMessage = message
            }
            wrote = true
            // The one and only place a bounce starts: arming a bubble is the event that
            // asks the user to come back. Losing focus later must NOT re-bounce — the
            // badge already carries that unread, and the window the user just left is
            // not news.
            dockAttention.bounce()
            refreshDockAttention()
        }
        // A notification means "look at this workspace". If its owning Space is
        // collapsed, the workspace row (and any attention bubble) is hidden, so expand
        // the Space to surface it — regardless of focus, since the user may have
        // collapsed a Space that still contains the selection. Guard on isCollapsed to
        // avoid a redundant no-op animation.
        if spaces[at.space].isCollapsed {
            withAnimation(.snappy) { mutateSpaces { $0[at.space].isCollapsed = false } }
            wrote = true
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
        guard wrote else { return true }
        persist()
        return true
    }

    /// Whether `workspaceID` delivered a notification within the last
    /// `notificationCooldown`, in which case a repeat should be suppressed.
    private func isWithinNotificationCooldown(_ workspaceID: UUID) -> Bool {
        guard let last = lastNotifiedAt[workspaceID] else { return false }
        return Date().timeIntervalSince(last) < Self.notificationCooldown
    }

    /// Replace the workspace's info-panel message and mark it unread, so the
    /// toolbar button pulses until the panel is shown. Deliberately independent
    /// of the attention subsystem: publishing info never raises the sidebar
    /// attention flag, posts no macOS notification, and never expands a
    /// collapsed Space — it is a passive act, unlike `controlRaiseNotification`.
    @discardableResult
    func controlSetInfo(markdown: String, for workspaceID: UUID) -> Bool {
        mutate(workspaceID) {
            $0.infoMarkdown = markdown
            $0.infoUnread = true
        }
    }

    /// Empty the workspace's info panel, which also hides its toolbar button.
    /// Clearing the unread flag alongside the message keeps a stale pulse from
    /// outliving the content that justified it.
    @discardableResult
    func controlClearInfo(for workspaceID: UUID) -> Bool {
        mutate(workspaceID) {
            $0.infoMarkdown = nil
            $0.infoUnread = false
        }
    }

    /// Mark the current info message as read — called when the panel is shown.
    /// Guarded on the flag so a repeated reveal does not write to `spaces` (and
    /// so does not fire its `didSet`) for nothing.
    func markInfoSeen(for workspaceID: UUID) {
        guard let at = locate(workspaceID), workspace(at: at).infoUnread else { return }
        updateWorkspace(at: at) { $0.infoUnread = false }
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
        refreshDockAttention()
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
            ControlWorkspaceInfo(id: $0.id.casperID, name: $0.name, branch: $0.branch, path: $0.worktreePath)
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
        guard let resolvedCwd = cwd ?? workspace(id: workspaceID)?.worktreePath else { return nil }
        let surface = Surface.terminal(cwd: resolvedCwd)
        guard insertTerminal(surface, in: workspaceID, command: command, orientation: orientation)
        else { return nil }
        return ControlTerminalInfo(id: surface.id.casperID, cwd: resolvedCwd)
    }

    // Reached from AppModel.swift.
    /// Insert `surface` into `workspaceID` by splitting its top-left surface along
    /// `orientation`, with `command` queued as the surface's initial input. Returns
    /// false when the workspace or its split anchor can't be resolved.
    ///
    /// The surface comes from the caller because `ScriptHookRunner` mints and tags its
    /// hook splits by id *before* the split runs, which is what lets it correlate their
    /// child-exit.
    ///
    /// A background (non-selected) workspace's views never mount on their own, so a
    /// queued command would never run: its surface would get no `GhosttySurfaceView` and
    /// no PTY, which for a `teardown` hook means no child-exit and a full 30 s timeout on
    /// every delete of an unselected workspace. Bring the pending surfaces up off-screen
    /// here, once, for both callers. The workspace is re-fetched because the one resolved
    /// above predates the split and does not carry the new surface.
    func insertTerminal(
        _ surface: Surface, in workspaceID: UUID, command: String?,
        orientation: LayoutNode.Orientation
    ) -> Bool {
        guard let ws = workspace(id: workspaceID),
              let anchor = LayoutTree.surfaceIDs(ws.layout).first,
              let at = locateSurface(anchor) else { return false }
        if let command { pendingInitialInput[surface.id] = command }
        insertSurfaceBySplitting(
            at: at, focused: anchor, orientation: orientation, side: .after, surface: surface)
        if command != nil, selectedWorkspaceID != workspaceID, let refreshed = workspace(id: workspaceID) {
            materializePendingSurfacesOffscreen(in: refreshed)
        }
        return true
    }

    // MARK: - `.casper.json` lifecycle hooks

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
            return ControlTerminalInfo(id: surface.id.casperID, cwd: cwd)
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
        guard navigateInspectorBrowser(to: url, in: workspaceID) else { return false }
        setInspectorTab(.browser, for: workspaceID)   // selects the browser tab, expands, persists
        return true
    }

    /// Load `url` into `workspaceID`'s inspector browser surface WITHOUT touching
    /// the inspector: unlike `controlOpenBrowser`, it never selects the browser tab
    /// or expands the panel, so it drives a hidden/unselected browser in the
    /// background (useful for parallel automation of a browser that isn't visible).
    @discardableResult
    func controlLoadBrowser(url: URL, in workspaceID: UUID) -> Bool {
        guard navigateInspectorBrowser(to: url, in: workspaceID) else { return false }
        scheduleSave()   // persist the new URL exactly like `setBrowserURL`
        return true
    }

    /// Point `workspaceID`'s inspector browser surface at `url` and make the cached
    /// coordinator show it, without revealing or persisting anything — the caller
    /// decides whether to expand the panel (`controlOpenBrowser`) or merely save
    /// (`controlLoadBrowser`). Returns false when the workspace is unknown.
    private func navigateInspectorBrowser(to url: URL, in workspaceID: UUID) -> Bool {
        guard let at = locate(workspaceID) else { return false }
        // Reuse the existing browser surface id (like `setBrowserURL`) so the cached
        // `BrowserCoordinator`/`WKWebView` keyed on it is preserved rather than leaked,
        // keeping the page and its history across reopens.
        let existingID = workspace(at: at).inspector.browser.id
        let surface = Surface(id: existingID, kind: .browser(url: url))
        updateWorkspace(at: at) { $0.inspector.browser = surface }
        // A coordinator that already exists won't be re-initialized by the SwiftUI
        // view (which may not even have mounted it, when the panel is hidden), so it
        // won't pick up the new URL on its own: create-or-navigate it explicitly. A
        // freshly-created coordinator already loads the surface's URL at init, so only
        // navigate again when it pre-existed — avoiding a redundant double load.
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
        // Resolved first: an invalid file must fail without having opened anything.
        var scrollTarget: String?
        if let file, !file.isEmpty {
            guard let resolved = WorkspaceFilePath.resolve(file, inWorktree: worktree) else {
                return .failure(DiffOpenError(message: "file is outside the workspace: \(file)"))
            }
            guard FileManager.default.fileExists(atPath: resolved) else {
                return .failure(DiffOpenError(message: "file does not exist: \(file)"))
            }
            scrollTarget = WorkspaceFilePath.relative(resolved, toWorktree: worktree)
        }
        setInspectorTab(.diff, for: workspaceID)
        if let scrollTarget {
            requestDiffScroll(workspaceID: workspaceID, file: scrollTarget)
        }
        return .success(())
    }

    /// Collapse the inspector if `workspaceID`'s active tab is `.browser`.
    /// No-op (still succeeds) if the diff tab is active or the panel is
    /// already collapsed — the caller's goal ("browser not showing") already
    /// holds either way.
    @discardableResult
    func controlCloseBrowser(in workspaceID: UUID) -> Bool {
        collapseInspector(ifTabIs: .browser, in: workspaceID)
    }

    /// Collapse the inspector if `workspaceID`'s active tab is `.diff`.
    /// Mirrors `controlCloseBrowser`.
    @discardableResult
    func controlCloseDiff(in workspaceID: UUID) -> Bool {
        collapseInspector(ifTabIs: .diff, in: workspaceID)
    }

    /// Collapse `workspaceID`'s inspector when `tab` is the active one; leave it
    /// alone otherwise. Returns false only when the workspace is unknown.
    private func collapseInspector(ifTabIs tab: InspectorTab, in workspaceID: UUID) -> Bool {
        guard let ws = workspace(id: workspaceID) else { return false }
        if ws.inspector.tab == tab {
            setInspectorCollapsed(true, for: workspaceID)
        }
        return true
    }
}
