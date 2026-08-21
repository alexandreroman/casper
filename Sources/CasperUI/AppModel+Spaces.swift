import CasperCore
import Foundation

/// Space adoption and reunification: how a folder being opened becomes a Space,
/// joins the Space of a repository already open, or absorbs the Spaces rooted at
/// its own worktrees — plus the teardown shared by every path that drops a
/// workspace. Part of `AppModel`.
extension AppModel {
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
        mutateSpaces { $0 = Self.sortedByName(updated) }
        // `reunify` may have dropped a workspace that still carried an unread.
        refreshDockAttention()
        selectWorkspace(space.workspaces.first?.id)
        persist()
    }

    // Reached from AppModel.swift.
    /// `path` with symlinks resolved, so two spellings of the same folder compare
    /// equal (on macOS `/tmp/x` and `/private/tmp/x` are the same directory).
    static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// The id of the workspace Casper already tracks at `canonical`: either a Space
    /// rooted there (answering with its primary workspace) or any workspace whose
    /// worktree is that folder.
    private func trackedWorkspaceID(atCanonicalPath canonical: String) -> UUID? {
        for space in spaces {
            if Self.canonicalPath(space.folderPath) == canonical {
                return space.firstOrderedWorkspaceID
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
        // Resolve the primary by kind, not position: absorbed workspaces fork off the
        // absorbing Space's own branch, so reading a linked workspace here would base
        // them on the wrong branch.
        guard !absorbed.isEmpty,
              let primary = space.workspaces.first(where: { $0.kind == .primary }) else { return }
        space.workspaces.append(contentsOf: Self.linkedWorkspaces(
            absorbing: absorbed, baseBranch: primary.branch,
            excluding: Self.canonicalPath(primary.worktreePath)))
        let moved = Set(space.workspaces.map(\.id))
        for workspace in absorbed.flatMap(\.workspaces) where !moved.contains(workspace.id) {
            retire(workspace)
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
    private func adoptWorktree(
        at folderURL: URL, info: WorkspaceFactory.GitInfo, into spaceID: UUID
    ) {
        guard let si = spaces.firstIndex(where: { $0.id == spaceID }) else { return }
        // Read before the selection moves below, exactly as `createLinkedWorkspace` does.
        let inheritedEditor = selectedWorkspaceID.flatMap { workspace(id: $0) }?.lastUsedEditor
        let portBase: Int
        do { portBase = try portAllocator.allocate() } catch {
            CasperLog.app.failure("cannot adopt worktree: no free port block", error)
            return
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
        mutateSpaces { $0[si].workspaces.append(ws) }
        selectWorkspace(ws.id)
        persist()
    }

    // Reached from AppModel.swift.
    /// The workspace selection should fall back to after a removal: the first
    /// remaining workspace of `space` in display order if it still has one,
    /// otherwise the first workspace of the first remaining Space overall.
    func fallbackSelection(preferring space: Space?) -> UUID? {
        space?.firstOrderedWorkspaceID ?? spaces.first?.firstOrderedWorkspaceID
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

    // Reached from AppModel.swift.
    /// Release everything a workspace being dropped from the model still holds: its
    /// reserved port block, its cached surface views — the inspector browser lives
    /// outside the layout tree, so its coordinator has to be named explicitly alongside
    /// the terminal surfaces — and its entries in the transient per-workspace maps,
    /// which would otherwise accumulate across a long session's workspace churn.
    ///
    /// Shared by every path that drops a workspace (`removeSpace`, `removeWorkspace`,
    /// `reunify`) so the three can't drift apart.
    ///
    /// The Dock badge is deliberately *not* refreshed here, even though a dropped
    /// workspace's unread must not linger in it: `refreshDockAttention` counts what is
    /// in `spaces`, and `reunify` retires before its own write to `spaces` lands. Each
    /// of the three callers refreshes once its write has settled instead.
    func retire(_ ws: Workspace) {
        portAllocator.release(ws.portBase)
        discardSurfaceViews(LayoutTree.surfaceIDs(ws.layout) + [ws.inspector.browser.id])
        pruneTransientState(for: ws)
    }
}
