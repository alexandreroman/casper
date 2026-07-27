import CasperCore
import CasperGit
import Foundation

/// The Git diff read/cache layer: the working-tree-vs-HEAD diff of a workspace
/// (memoized and de-duplicated across concurrent callers) plus the two file-text
/// readers that feed the diff surface's syntax highlighting.
///
/// Deliberately knows nothing about `AppModel`: the one thing it needs — the
/// cache-invalidation key, `AppModel.diffRevision` — is injected as a closure, the
/// same test-seam idiom `AppModel` uses for `makeWorktreeWatcher` /
/// `deliverNotification` / `gitReprobe`. The revision token itself stays on
/// `AppModel`, where it is `@Observable` state the diff views watch directly.
@MainActor
final class DiffService {
    private let currentRevision: () -> Int

    /// - Parameters:
    ///   - currentRevision: The current diff revision token (`AppModel.diffRevision`),
    ///     read on every cache lookup and cache write.
    init(currentRevision: @escaping () -> Int) {
        self.currentRevision = currentRevision
    }

    /// Memoizes the last `computeDiff` result so the diff surface and the toolbar
    /// summary don't each recompute it for the same state. Keyed by the workspace
    /// id and the `diffRevision` at compute time, so a new selection or a
    /// filesystem-change bump invalidates it without an explicit clear.
    private var cachedDiff: (workspaceID: UUID, revision: Int, diff: GitDiff?)?

    /// The in-flight diff computation, so the diff surface and the toolbar summary
    /// don't each launch a concurrent identical libgit2 walk for the same
    /// `(workspace, revision)`: a second caller awaits this task instead.
    private var inFlightDiff: (workspaceID: UUID, revision: Int, task: Task<GitDiff?, Never>)?

    /// Compute the working-tree-vs-HEAD diff of a workspace's worktree. Returns nil
    /// when the workspace is not Git-backed or the diff fails.
    ///
    /// A memoized result matching the current `diffRevision` returns synchronously
    /// (no await). Otherwise the libgit2 walk runs off the main actor in a detached
    /// task that opens and uses its OWN `Repository` (never crossing an actor
    /// boundary), so the render/run loop isn't blocked; the `Sendable` `GitDiff`
    /// then crosses back. Concurrent callers for the same `(workspace, revision)`
    /// share one in-flight task, and the per-revision cache is written only when a
    /// newer revision hasn't already superseded the result.
    func computeDiff(for workspace: Workspace) async -> GitDiff? {
        if let cached = cachedDiff, cached.workspaceID == workspace.id, cached.revision == currentRevision() {
            return cached.diff
        }
        let revision = currentRevision()
        if let inFlight = inFlightDiff, inFlight.workspaceID == workspace.id, inFlight.revision == revision {
            return await inFlight.task.value
        }

        let path = workspace.worktreePath
        let task = Task.detached(priority: .userInitiated) { () -> GitDiff? in
            do {
                let repo = try Repository.open(atPath: path)
                return try repo.diffWorkdirToHead()
            } catch {
                CasperLog.app.failure("diff failed", error)
                return nil
            }
        }
        inFlightDiff = (workspace.id, revision, task)
        let diff = await task.value

        // Don't cache a result a newer revision has already superseded.
        if currentRevision() == revision {
            cachedDiff = (workspace.id, revision, diff)
        }
        // Clear the in-flight entry only if it's still the one we started.
        if let inFlight = inFlightDiff, inFlight.workspaceID == workspace.id, inFlight.revision == revision {
            inFlightDiff = nil
        }
        return diff
    }

    /// The workspace's working-tree-vs-HEAD line counts, or nil when not
    /// Git-backed or the diff fails. Feeds the detail toolbar's `+INS −DEL`.
    func diffSummary(for workspace: Workspace) async -> (insertions: Int, deletions: Int)? {
        await computeDiff(for: workspace).map { ($0.insertions, $0.deletions) }
    }

    /// The full UTF-8 text of `path` in the workspace's HEAD commit, or nil when
    /// the path is empty/absent, the blob is binary, exceeds
    /// `DiffHighlighter.maxHighlightBytes`, or the read fails. This is the
    /// "before" side of the diff, feeding syntax highlighting.
    func headFileText(for workspace: Workspace, path: String) -> String? {
        guard !path.isEmpty else { return nil }
        do {
            let repo = try Repository.open(atPath: workspace.worktreePath)
            guard let text = try repo.fileTextAtHead(path: path) else { return nil }
            // Mirror worktreeFileText's cap: keep oversized blobs out of the highlighter.
            guard text.utf8.count <= DiffHighlighter.maxHighlightBytes else { return nil }
            return text
        } catch {
            CasperLog.app.failure("read HEAD file text failed", error)
            return nil
        }
    }

    /// The full UTF-8 text of `path` on disk in the workspace's worktree, or nil
    /// when the path is empty, the file is missing/unreadable, exceeds
    /// `DiffHighlighter.maxHighlightBytes`, or is not valid UTF-8. This is the
    /// "after" side of the diff, feeding syntax highlighting. Never throws.
    func worktreeFileText(for workspace: Workspace, path: String) -> String? {
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: workspace.worktreePath).appendingPathComponent(path)
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            if let size, size > DiffHighlighter.maxHighlightBytes { return nil }
            let data = try Data(contentsOf: url)
            guard data.count <= DiffHighlighter.maxHighlightBytes else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
