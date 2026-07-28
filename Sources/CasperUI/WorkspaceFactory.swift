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

        init(
            canonicalPath: String, branch: String, remoteURL: String?,
            commonDirPath: String? = nil, isLinkedWorktree: Bool = false
        ) {
            self.canonicalPath = canonicalPath
            self.branch = branch
            self.remoteURL = remoteURL
            self.commonDirPath = commonDirPath
            self.isLinkedWorktree = isLinkedWorktree
        }
    }

    static func makeSpace(
        folderURL: URL, probe: (URL) -> GitInfo?, portBase: Int
    ) -> Space {
        makeSpace(folderURL: folderURL, info: probe(folderURL), portBase: portBase)
    }

    /// Variant taking an already-probed `info`, for callers that inspect the probe
    /// result before deciding what to build (see `AppModel.addSpace`, which routes a
    /// worktree of an open repository into that repository's Space instead).
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
