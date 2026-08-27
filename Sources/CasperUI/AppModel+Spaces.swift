import CasperCore
import CasperGit
import Foundation

/// Space adoption, creation and reunification: how a folder being opened becomes a
/// Space, joins the Space of a repository already open, or absorbs the Spaces rooted
/// at its own worktrees; how a Space is made from nothing at all — plus the teardown
/// shared by every path that drops a workspace. Part of `AppModel`.
extension AppModel {
    /// What `addSpace(folderURL:probe:)` did, so the caller — and only the caller —
    /// decides whether to put an alert on screen. `addSpace` never runs a modal
    /// itself: it is also driven headlessly, by the tests.
    enum AddSpaceOutcome: Equatable {
        /// The folder is now open, as a Space of its own or as a workspace of one.
        case added
        /// The folder was already open: its workspace was selected instead.
        case selected
        /// Nothing was added.
        case failed(reason: Failure)

        /// Why a folder could not be added.
        enum Failure: Equatable {
            /// The folder is a worktree of a **bare** repository: a Space roots at a main
            /// working tree and a bare repository has none, so Casper does not support
            /// that layout.
            case bareRepository
            /// The folder is a linked worktree whose repository's main working tree did
            /// not resolve to a folder of that same repository — gone from disk, or never
            /// named correctly in the first place — so there is nothing to root its Space
            /// at.
            case mainWorkingTreeUnresolved
            /// No free port block is left for the workspaces the folder needs.
            case noFreePortBlock
        }
    }

    /// The outcome of creating a Space from scratch, in the same shape as
    /// `AddSpaceOutcome`: `createSpace` never puts an alert on screen — it is also
    /// driven headlessly, by the tests — so the caller decides what the user sees.
    enum CreateSpaceOutcome: Equatable {
        /// The folder was created, initialized as a Git repository, and is now open.
        ///
        /// Also reported when adoption *selected* an existing workspace rather than
        /// adding one — reachable when a Space is still tracked at a path whose folder
        /// was deleted outside Casper. The two are deliberately not told apart: every
        /// caller treats any non-failure identically, so a case of its own would only
        /// be a distinction nobody acts on.
        case created
        /// Nothing that was on disk *before this call* was removed or overwritten: a
        /// directory this call made is rolled back, as is a `.git` it initialized inside
        /// a directory the user handed over, and anything else stays exactly as found.
        case failed(reason: Failure)

        /// Why a Space could not be created.
        enum Failure: Equatable {
            /// A file, or a folder holding something, already sits at the chosen path.
            /// Casper never deletes or overwrites what it did not create, so the user has
            /// to pick another name or another location.
            case pathOccupied
            /// The folder itself could not be created, `message` being what the filesystem
            /// said about it (no write permission, read-only volume, name too long…).
            case directoryNotCreated(message: String)
            /// The folder was created but `git init` failed in it, `message` being what
            /// libgit2 said about it.
            case repositoryNotInitialized(message: String)
            /// The repository was created but could not be opened as a Space. Carries the
            /// adoption failure verbatim so the caller reuses the wording it already has
            /// for "Add Folder…".
            case notAdopted(reason: AddSpaceOutcome.Failure)
        }
    }

    /// Adopt `folderURL` into the session, keeping one Space per Git repository:
    ///
    /// - a folder that is a linked worktree of a repository already open joins that
    ///   repository's Space as a linked workspace — a worktree is part of its repo,
    ///   not a project of its own;
    /// - a folder that is a linked worktree of a repository *not* open pulls that
    ///   repository in: the Space roots at the repository's main working tree and the
    ///   chosen worktree joins it, so the shape is the same either way;
    /// - a folder that is a repository whose worktrees are already open as Spaces of
    ///   their own becomes their Space, reunifying them into it as linked workspaces;
    /// - any other folder becomes a Space, as before.
    ///
    /// A folder that is already tracked (as a Space or as one of its workspaces) is
    /// not added twice: it is just selected.
    @discardableResult
    func addSpace(folderURL: URL, probe: (URL) -> WorkspaceFactory.GitInfo?) -> AddSpaceOutcome {
        let folderPath = folderURL.path
        let candidate = Self.canonicalPath(folderPath)
        if let known = trackedWorkspace(atCanonicalPath: candidate) {
            CasperLog.app.error("folder already open: \(folderPath, privacy: .public)")
            selectWorkspace(known.workspaceID)
            return .selected
        }
        let info = probe(folderURL)
        if let info, info.isLinkedWorktree {
            if let si = spaceIndexSharingRepository(with: info, probe: probe) {
                return adoptWorktree(at: folderURL, info: info, into: si)
            }
            return addSpacePullingInRepository(ofWorktreeAt: folderURL, info: info, probe: probe)
        }
        let portBase: Int
        do {
            portBase = try portAllocator.allocate()
        } catch {
            CasperLog.app.failure("cannot add space: no free port block", error)
            return .failed(reason: .noFreePortBlock)
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
        // The new Space's primary is freshly minted, so the selection always changes
        // and `selectWorkspace` is also the save.
        selectWorkspace(space.workspaces.first?.id)
        return .added
    }

    /// Open the repository of a linked worktree no open Space shares: the Space roots
    /// at the repository's **main working tree**, built exactly as opening that folder
    /// would build it, and `folderURL` joins it as a linked workspace — the same shape
    /// `adoptWorktree` produces. A worktree is part of its repository, so opening one
    /// opens the repository.
    ///
    /// Nothing is created on disk and the repo's `setup` hook does not run: both
    /// working trees already exist, and the hook fires at creation only (same
    /// rationale as `adoptWorktree`).
    ///
    /// Nothing is absorbed either. The caller reaches this only after
    /// `spaceIndexSharingRepository` answered nil, so no open Space is backed by this
    /// repository and `reunify` would provably have nothing to fold in.
    ///
    /// Fails, adding nothing, when there is no main working tree to root at: the
    /// repository is bare — a layout Casper does not support — or the folder libgit2
    /// names is gone from disk, or is not a working tree of this repository at all (the
    /// `--separate-git-dir` case, caught by the same-repository guard below rather than
    /// by failing to resolve). Rooting the Space at the worktree instead is exactly the
    /// shape this path exists to avoid, so the folder is refused and the caller reports
    /// it.
    private func addSpacePullingInRepository(
        ofWorktreeAt folderURL: URL, info: WorkspaceFactory.GitInfo,
        probe: (URL) -> WorkspaceFactory.GitInfo?
    ) -> AddSpaceOutcome {
        guard !info.isBareRepository else {
            CasperLog.app.error(
                "cannot add worktree: its repository is bare, at \(folderURL.path, privacy: .public)")
            return .failed(reason: .bareRepository)
        }
        guard let mainPath = info.mainWorkingTreePath, Self.directoryExists(atPath: mainPath) else {
            CasperLog.app.error(
                "cannot add worktree: main working tree not found on disk for \(folderURL.path, privacy: .public)")
            return .failed(reason: .mainWorkingTreeUnresolved)
        }
        let mainURL = URL(fileURLWithPath: mainPath)
        // That path is only what libgit2 derived, so check it really is this
        // repository's main working tree: `git init --separate-git-dir` records no
        // `core.worktree`, and libgit2 then answers the git directory's parent — an
        // existing folder, which in a nested layout is a repository of its own.
        guard let mainInfo = probe(mainURL), !mainInfo.isLinkedWorktree,
              mainInfo.commonDirPath == info.commonDirPath else {
            CasperLog.app.error(
                "cannot add worktree: not its repository's main working tree at \(mainPath, privacy: .public)")
            return .failed(reason: .mainWorkingTreeUnresolved)
        }
        // The repository's own folder can already be open while `spacesSharingRepository`
        // fails to see it: that lookup also requires `Space.isGitRepo`, which is not
        // persisted — `resolveGitBacking()` sets it once at launch, and a Space whose
        // launch probe transiently failed stays flagged non-Git for the session unless
        // it is selected. Building a Space here would then root a second one at the same
        // folder, each with a `.primary` on the same working tree, which is exactly what
        // `linkedWorkspaces(absorbing:baseBranch:excluding:)` guards against on the
        // reunify side. Adopt into the Space already tracking that folder instead.
        if let tracked = trackedWorkspace(atCanonicalPath: Self.canonicalPath(mainPath)) {
            return adoptWorktree(at: folderURL, info: info, into: tracked.spaceIndex)
        }
        // Two workspaces, so two port blocks: the repository's primary and the worktree.
        let portBase: Int
        let worktreePortBase: Int
        do {
            portBase = try portAllocator.allocate()
        } catch {
            CasperLog.app.failure("cannot add space: no free port block", error)
            return .failed(reason: .noFreePortBlock)
        }
        do {
            worktreePortBase = try portAllocator.allocate()
        } catch {
            // Nothing is added, so nothing may stay reserved.
            portAllocator.release(portBase)
            CasperLog.app.failure("cannot adopt worktree: no free port block", error)
            return .failed(reason: .noFreePortBlock)
        }
        var space = WorkspaceFactory.makeSpace(
            folderURL: mainURL, info: mainInfo, portBase: portBase)
        let branch = info.branch
        let baseBranch = space.primaryWorkspace?.branch ?? ""
        var adopted = WorkspaceFactory.makeLinkedWorkspace(
            name: branch.isEmpty ? folderURL.lastPathComponent : branch,
            worktreePath: info.canonicalPath, branch: branch,
            baseBranch: baseBranch, portBase: worktreePortBase)
        // Read before the selection moves below, exactly as `adoptWorktree` does.
        adopted.lastUsedEditor = inheritedEditor
        space.workspaces.append(adopted)
        var updated = spaces
        updated.append(space)
        mutateSpaces { $0 = Self.sortedByName(updated) }
        // The folder the user picked is the worktree, not the repository pulled in
        // behind it, so that is what the selection lands on. The selection always
        // changes here, so `selectWorkspace` is also the save.
        selectWorkspace(adopted.id)
        return .added
    }

    /// Create a Space from nothing: make the directory at `folderURL`, turn it into a
    /// Git repository, and open it — the counterpart of `addSpace`, which adopts a
    /// folder that already exists.
    ///
    /// The repository gets **one empty initial commit** and nothing else: no README, no
    /// `.gitignore`. What a project starts with is the user's call (and their
    /// `init.templateDir`'s), not Casper's — but a repository with no commit at all
    /// cannot host a workspace, since `git worktree add` bases the new worktree on a
    /// commit resolved through HEAD, and `git init` leaves HEAD unborn. One empty
    /// commit is the smallest thing that makes "New Space…" followed by "Create
    /// Workspace…" work.
    ///
    /// That commit is **not** part of the rollback: it can be skipped (see
    /// `Repository.createInitialCommit`, which writes nothing when the machine
    /// configures no committer identity) or fail outright, and either way the
    /// repository on disk is a valid one that is still worth adopting. Only
    /// `Repository.initialize` failing and the adoption failing roll anything back.
    ///
    /// A path that is already taken is refused rather than reused: Casper never
    /// deletes or overwrites anything it did not create. The one exception is an
    /// **empty** directory, which is what both of the save panel's own paths hand over
    /// — its "New Folder" button, and confirming "Replace" on a folder it just made.
    ///
    /// Rollback is scoped to what *this call* created: when `git init` or the adoption
    /// fails, a directory Casper made is removed again, and a `.git` Casper initialized
    /// inside a directory the user handed over is removed on its own. So a failed
    /// creation leaves neither a half-initialized folder behind nor — just as important
    /// — a leftover `.git` that would make the very same path un-creatable on a second
    /// attempt, `isVacant` seeing a folder the Finder still shows as empty. The empty
    /// directory itself survives: it is the user's, and they may well have meant to
    /// keep it.
    ///
    /// `git init` and the rollback both run synchronously on the main actor, which on a
    /// slow or network volume can block it long enough to trip the debug hang watchdog.
    /// That is a deliberate cost, consistent with `gitProbe`: creation is a one-shot,
    /// user-initiated action whose result the very next line of UI depends on, and
    /// hopping off the actor would buy nothing but a race with the model it writes to.
    ///
    /// The probe is `@MainActor` where `addSpace`'s is not, only so that
    /// `AppModel.gitProbe` — a static member of a `@MainActor` type, hence isolated to
    /// it — can be spelled as the default. Handing it on to `addSpace` drops the
    /// isolation again, which this main-actor body is allowed to do.
    @discardableResult
    func createSpace(
        at folderURL: URL, probe: @MainActor (URL) -> WorkspaceFactory.GitInfo? = AppModel.gitProbe
    ) -> CreateSpaceOutcome {
        guard Self.isVacant(atPath: folderURL.path) else {
            CasperLog.app.error(
                "cannot create space: \(folderURL.path, privacy: .public) is already taken")
            return .failed(reason: .pathOccupied)
        }
        // The create itself decides whether Casper owns this directory: `mkdir(2)` either
        // makes it or reports that something is already there, so the rollback below acts
        // on what *this call* did rather than on what a separate stat saw a moment
        // earlier — a stat whose answer another process could invalidate in between,
        // turning the recursive removal loose on a directory that is not Casper's.
        // Without intermediate directories, both because the save panel always hands over
        // an existing parent and because a parent created here would be a second thing to
        // roll back. `mkdir(2)` never *follows* a final symlink — but it does report one
        // as `EEXIST`, indistinguishable from the empty directory this call is willing to
        // build in, which is why that branch checks the path again instead of assuming.
        let didCreateDirectory: Bool
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: false)
            didCreateDirectory = true
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            // Something was already there. The `isVacant` above cleared it as an empty
            // directory of the user's — build in it, but do not claim it — except that
            // its answer is now stale by one syscall: a symlink to a directory planted in
            // between lands here too, and following it would `git init` in the link's
            // target and root the Space somewhere other than the path the user named.
            // Re-checking narrows that to the window `mkdir(2)` itself cannot close.
            guard Self.isVacant(atPath: folderURL.path) else {
                CasperLog.app.error(
                    "cannot create space: \(folderURL.path, privacy: .public) is already taken")
                return .failed(reason: .pathOccupied)
            }
            didCreateDirectory = false
        } catch {
            CasperLog.app.failure("cannot create space: folder not created", error)
            return .failed(reason: .directoryNotCreated(message: error.localizedDescription))
        }

        // Undo what this call put on disk, and only that: the whole directory when Casper
        // made it, otherwise the `.git` Casper initialized inside the user's directory —
        // that `.git` is Casper's, and leaving it behind would lock the path out of any
        // retry. Best-effort: the creation has failed either way, and something that
        // resists removal is better reported as the original failure than as a second,
        // more confusing one.
        func rollBackWhatThisCallCreated() {
            if didCreateDirectory {
                try? FileManager.default.removeItem(at: folderURL)
            } else {
                try? FileManager.default.removeItem(at: folderURL.appendingPathComponent(".git"))
            }
        }

        // The handle is held only long enough for the initial commit: the repository
        // lives on disk from here on, and every later read (`gitProbe`, the worktree
        // manager) reopens it.
        let repository: Repository
        do {
            repository = try Repository.initialize(atPath: folderURL.path)
        } catch {
            CasperLog.app.failure("cannot create space: git init failed", error)
            rollBackWhatThisCallCreated()
            return .failed(reason: .repositoryNotInitialized(message: error.localizedDescription))
        }
        writeInitialCommit(in: repository, at: folderURL)

        switch addSpace(folderURL: folderURL, probe: probe) {
        case .added, .selected:
            return .created
        case .failed(let reason):
            CasperLog.app.error(
                "cannot create space: \(folderURL.path, privacy: .public) was not adopted")
            rollBackWhatThisCallCreated()
            return .failed(reason: .notAdopted(reason: reason))
        }
    }

    /// Give a just-initialized repository its first commit, so the Space about to be
    /// built on it can host a workspace right away.
    ///
    /// Reports only to the log, deliberately: every outcome — the commit written, the
    /// commit skipped for want of a configured Git identity, or libgit2 refusing it —
    /// leaves a valid repository behind, so none of them is a reason to refuse the
    /// Space or to undo what is already on disk. A Space left on an unborn HEAD is
    /// still a Space; creating a workspace in it is what then says so, in Casper's own
    /// words (`WorktreeError.Reason.repositoryHasNoCommits`).
    private func writeInitialCommit(in repository: Repository, at folderURL: URL) {
        do {
            guard try repository.createInitialCommit() else {
                // A documented outcome, not a failure: the Space is still built, and the
                // level says so.
                CasperLog.app.notice(
                    "new space has no initial commit: no git user identity, at \(folderURL.path, privacy: .public)")
                return
            }
        } catch {
            CasperLog.app.failure("new space has no initial commit", error)
        }
    }

    /// True when a Space may be created at `path`: either nothing is there, or a
    /// directory that holds nothing but a `.DS_Store` — the file the Finder drops into
    /// a folder merely by showing it, which says nothing about the folder being used.
    ///
    /// A symlink counts as taken whatever it points at, empty target included: every
    /// other check here resolves it, so `git init` would run in the target and the Space
    /// would root somewhere other than the path the user named.
    ///
    /// An unreadable directory counts as taken too: what it holds cannot be checked, and
    /// the safe reading of "cannot tell" is "do not touch".
    private static func isVacant(atPath path: String) -> Bool {
        // `attributesOfItem` describes the link rather than its target, so a dangling
        // symlink — which `fileExists` reports as nothing at all — is caught as well.
        if let attributes = try? FileManager.default.attributesOfItem(atPath: path),
           attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            return false
        }
        guard FileManager.default.fileExists(atPath: path) else { return true }
        guard directoryExists(atPath: path),
              let contents = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return false
        }
        return contents.allSatisfy { $0 == ".DS_Store" }
    }

    // Reached from AppModel+Control.swift and from the panel presenters in
    // AppModel+Presentation.swift.
    /// True when `path` is an existing directory (a plain file at that path is not one).
    static func directoryExists(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    // Reached from AppModel.swift.
    /// `path` with symlinks resolved, so two spellings of the same folder compare
    /// equal (on macOS `/tmp/x` and `/private/tmp/x` are the same directory).
    static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// The workspace Casper already tracks at `canonical` — either a Space rooted
    /// there (answering with its primary workspace) or any workspace whose worktree is
    /// that folder — together with the index of the Space holding it, for the callers
    /// that go on to mutate that Space.
    private func trackedWorkspace(
        atCanonicalPath canonical: String
    ) -> (spaceIndex: Int, workspaceID: UUID)? {
        for (si, space) in spaces.enumerated() {
            if Self.canonicalPath(space.folderPath) == canonical {
                return space.firstOrderedWorkspaceID.map { (si, $0) }
            }
            if let match = space.workspaces.first(where: {
                Self.canonicalPath($0.worktreePath) == canonical
            }) {
                return (si, match.id)
            }
        }
        return nil
    }

    /// An open Space that turns out to be backed by the same Git repository as a
    /// folder being added: its index in `spaces`, and which of the repository's working
    /// trees it roots at. Its index rather than the Space itself, so a caller that goes
    /// on to mutate it has no "no such Space" branch to write that could never be taken.
    private struct RepositoryMatch {
        let spaceIndex: Int
        let isLinkedWorktree: Bool
    }

    /// Every open Space backed by the same Git repository as `info` — same common
    /// `.git` directory, which all of a repository's working trees share.
    private func spacesSharingRepository(
        with info: WorkspaceFactory.GitInfo, probe: (URL) -> WorkspaceFactory.GitInfo?
    ) -> [RepositoryMatch] {
        guard let commonDir = info.commonDirPath else { return [] }
        return spaces.indices.compactMap { si in
            guard spaces[si].isGitRepo,
                  let spaceInfo = probe(URL(fileURLWithPath: spaces[si].folderPath)),
                  spaceInfo.commonDirPath == commonDir else { return nil }
            return RepositoryMatch(spaceIndex: si, isLinkedWorktree: spaceInfo.isLinkedWorktree)
        }
    }

    /// The index of the Space a worktree described by `info` should join, or nil when
    /// its repository isn't open. When both a repository's main working tree and one of
    /// its worktrees are open as Spaces, the main working tree wins: its folder is
    /// what worktree operations (create, prune, merge) run against.
    private func spaceIndexSharingRepository(
        with info: WorkspaceFactory.GitInfo, probe: (URL) -> WorkspaceFactory.GitInfo?
    ) -> Int? {
        let matches = spacesSharingRepository(with: info, probe: probe)
        return (matches.first(where: { !$0.isLinkedWorktree }) ?? matches.first)?.spaceIndex
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
            .map { spaces[$0.spaceIndex] }
    }

    /// Move every workspace of `absorbed` into `space` as a linked workspace (see
    /// `linkedWorkspaces`), tearing down whatever cannot be carried over so a dropped
    /// workspace leaves behind neither a reserved port nor a cached view. The
    /// absorbed Spaces themselves are dropped by the caller, in the same write that
    /// installs `space`.
    private func reunify(_ absorbed: [Space], into space: inout Space) {
        guard !absorbed.isEmpty, let primary = space.primaryWorkspace else { return }
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

    /// Add an existing worktree to the Space at index `si` as a linked workspace.
    /// Unlike `createLinkedWorkspace` nothing is created on disk — the branch and the
    /// worktree already exist, Casper merely starts tracking them — so the repo's
    /// `setup` hook does not run: it fires at creation only.
    ///
    /// Takes the Space's index rather than its id because the caller has just resolved
    /// it: there is then no "no such Space" branch here that could never be taken.
    private func adoptWorktree(
        at folderURL: URL, info: WorkspaceFactory.GitInfo, into si: Int
    ) -> AddSpaceOutcome {
        let portBase: Int
        do { portBase = try portAllocator.allocate() } catch {
            CasperLog.app.failure("cannot adopt worktree: no free port block", error)
            return .failed(reason: .noFreePortBlock)
        }
        // Same shape as a Casper-created linked workspace: named after its branch,
        // with the Space's primary branch as the base it merges back into. A worktree
        // with no branch name of its own falls back to its folder name.
        let branch = info.branch
        let baseBranch = spaces[si].primaryWorkspace?.branch ?? ""
        var ws = WorkspaceFactory.makeLinkedWorkspace(
            name: branch.isEmpty ? folderURL.lastPathComponent : branch,
            worktreePath: info.canonicalPath, branch: branch,
            baseBranch: baseBranch, portBase: portBase)
        // Read before the selection moves below, exactly as `createLinkedWorkspace` does.
        ws.lastUsedEditor = inheritedEditor
        mutateSpaces { $0[si].workspaces.append(ws) }
        // The selection always changes here, so `selectWorkspace` is also the save.
        selectWorkspace(ws.id)
        return .added
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
        namedCommandsStamps[ws.id] = nil
        watcherPathsCache[ws.id] = nil
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
