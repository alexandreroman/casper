import CasperCore
import Foundation

/// Pure builder turning an adopted folder into a `Workspace`. `probe` returns
/// repository info when the folder is Git-backed and `nil` otherwise; the
/// factory never touches disk itself, so it is fully testable.
enum WorkspaceFactory {
    struct RepoInfo: Equatable {
        let repoPath: String
        let branch: String
    }

    static func makeWorkspace(
        folderURL: URL, probe: (URL) -> RepoInfo?, portBase: Int
    ) -> Workspace {
        let folderPath = folderURL.path
        let info = probe(folderURL)
        return Workspace(
            name: folderURL.lastPathComponent,
            repoPath: info?.repoPath ?? folderPath,
            worktreePath: folderPath,
            branch: info?.branch ?? "",
            portBase: portBase,
            layout: .tabGroup(
                surfaces: [Surface(kind: .terminal(cwd: folderPath, command: nil))],
                activeIndex: 0
            )
        )
    }
}
