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
    }

    static func makeSpace(
        folderURL: URL, probe: (URL) -> GitInfo?, portBase: Int
    ) -> Space {
        let folderPath = folderURL.path
        let info = probe(folderURL)
        let canonical = info?.canonicalPath ?? folderPath
        let name = SpaceName.derive(
            remoteURL: info?.remoteURL, folderName: folderURL.lastPathComponent)
        let primary = Workspace(
            name: name,
            worktreePath: canonical,
            branch: info?.branch ?? "",
            portBase: portBase,
            layout: .tabGroup(
                surfaces: [Surface(kind: .terminal(cwd: canonical, command: nil))],
                activeIndex: 0),
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
            layout: .tabGroup(
                surfaces: [Surface(kind: .terminal(cwd: worktreePath, command: nil))],
                activeIndex: 0),
            kind: .linked,
            baseBranch: baseBranch)
    }
}
