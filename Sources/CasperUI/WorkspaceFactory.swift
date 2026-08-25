import CasperCore
import Foundation

/// Pure builder turning an adopted folder into a `Space` with one primary
/// `Workspace`. `probe` returns Git info when the folder is Git-backed and `nil`
/// otherwise; the factory never touches disk itself, so it is fully testable.
enum WorkspaceFactory {
    struct GitInfo: Equatable {
        let canonicalPath: String
        let branch: String
        let remoteURL: String?
        /// The repository's common `.git` directory: the identity shared by its main
        /// working tree and every linked worktree, so two folders belong to the same
        /// repository exactly when these match. Nil when the prober doesn't report it.
        let commonDirPath: String?
        /// True when the probed folder is a linked worktree rather than the
        /// repository's main working tree.
        let isLinkedWorktree: Bool
        /// The repository's main working tree directory — the folder a Space for this
        /// repository roots at, whichever of its working trees was probed. It is the
        /// same string as `canonicalPath` when the probed folder *is* the main working
        /// tree: the same libgit2 workdir, put through the same normalizer. Nil when
        /// the prober doesn't report it, when the repository is bare
        /// (`isBareRepository`), or when it is no longer reachable from the probed
        /// worktree.
        ///
        /// Not verified to belong to the probed folder's repository: in a
        /// `--separate-git-dir` layout libgit2 derives it from the git directory's
        /// parent, an unrelated existing folder. `AppModel.addSpace` re-probes it and
        /// compares common directories before rooting anything at it.
        let mainWorkingTreePath: String?
        /// True when the repository behind the probed folder — the one its common
        /// `.git` directory belongs to — is bare, so it has no main working tree and
        /// never will. Distinct from a main working tree that merely failed to resolve.
        let isBareRepository: Bool

        init(
            canonicalPath: String, branch: String, remoteURL: String?,
            commonDirPath: String? = nil, isLinkedWorktree: Bool = false,
            mainWorkingTreePath: String? = nil, isBareRepository: Bool = false
        ) {
            self.canonicalPath = canonicalPath
            self.branch = branch
            self.remoteURL = remoteURL
            self.commonDirPath = commonDirPath
            self.isLinkedWorktree = isLinkedWorktree
            self.mainWorkingTreePath = mainWorkingTreePath
            self.isBareRepository = isBareRepository
        }
    }

    /// Build a Space from an already-probed `info` (nil ⇒ the folder is not
    /// Git-backed). The probe stays with the caller, which inspects its result
    /// before deciding what to build — see `AppModel.addSpace`, which routes a
    /// worktree of an already-open repository into that repository's Space instead.
    static func makeSpace(
        folderURL: URL, info: GitInfo?, portBase: Int
    ) -> Space {
        let folderPath = folderURL.path
        let canonical = info?.canonicalPath ?? folderPath
        let name = SpaceName.derive(
            remoteURL: info?.remoteURL, folderName: folderURL.lastPathComponent)
        let primary = Workspace(
            name: name,
            worktreePath: canonical,
            branch: info?.branch ?? "",
            portBase: portBase,
            layout: .leaf(.terminal(cwd: canonical)),
            kind: .primary
        )
        return Space(
            name: name, folderPath: canonical, isGitRepo: info != nil,
            workspaces: [primary])
    }

    static func makeLinkedWorkspace(
        name: String, worktreePath: String, branch: String,
        baseBranch: String, portBase: Int
    ) -> Workspace {
        Workspace(
            name: name,
            worktreePath: worktreePath,
            branch: branch,
            portBase: portBase,
            layout: .leaf(.terminal(cwd: worktreePath)),
            kind: .linked,
            baseBranch: baseBranch)
    }
}
