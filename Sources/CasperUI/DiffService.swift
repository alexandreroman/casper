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

    /// The "before" (HEAD) and "after" (worktree) texts of many paths at once,
    /// feeding the diff surface's syntax highlighting.
    ///
    /// Every read runs in **one** detached task that opens a **single**
    /// `Repository` and uses it entirely inside itself (never crossing an actor
    /// boundary), the same shape `computeDiff` uses; only the `Sendable` strings
    /// cross back. Reading file by file from the main actor instead would put one
    /// `Repository.open` plus one up-to-`DiffHighlighter.maxHighlightBytes` read
    /// and UTF-8 decode per file on the render loop — 50 libgit2 opens for a
    /// 50-file first load, which is the diff view's documented hang path.
    ///
    /// A path that is empty, absent, binary, oversized, unreadable or not valid
    /// UTF-8 simply has no entry, so one unreadable file costs nothing but its own
    /// colors. A repository that won't open leaves `head` empty and still reads
    /// the worktree side.
    func fileTexts(
        for workspace: Workspace, headPaths: [String], worktreePaths: [String]
    ) async -> DiffFileTexts {
        let worktreeRoot = workspace.worktreePath
        return await Task.detached(priority: .userInitiated) { () -> DiffFileTexts in
            var head: [String: String] = [:]
            do {
                let repo = try Repository.open(atPath: worktreeRoot)
                for path in headPaths where !path.isEmpty {
                    head[path] = Self.headText(of: path, in: repo)
                }
            } catch {
                CasperLog.app.failure("open repository for HEAD file texts failed", error)
            }
            var worktree: [String: String] = [:]
            for path in worktreePaths where !path.isEmpty {
                worktree[path] = Self.worktreeText(of: path, underWorktreeAt: worktreeRoot)
            }
            return DiffFileTexts(head: head, worktree: worktree)
        }.value
    }

    /// The full UTF-8 text of `path` in `repo`'s HEAD commit, or nil when the blob
    /// is absent, binary, exceeds `DiffHighlighter.maxHighlightBytes`, or the read
    /// fails.
    private nonisolated static func headText(of path: String, in repo: Repository) -> String? {
        do {
            guard let text = try repo.fileTextAtHead(path: path) else { return nil }
            // Mirror worktreeText's cap: keep oversized blobs out of the highlighter.
            guard text.utf8.count <= DiffHighlighter.maxHighlightBytes else { return nil }
            return text
        } catch {
            CasperLog.app.failure("read HEAD file text failed", error)
            return nil
        }
    }

    /// The full UTF-8 text of `path` on disk under `worktreeRoot`, or nil when the
    /// file is missing/unreadable, exceeds `DiffHighlighter.maxHighlightBytes`, or
    /// is not valid UTF-8. Never throws.
    private nonisolated static func worktreeText(
        of path: String, underWorktreeAt worktreeRoot: String
    ) -> String? {
        let url = URL(fileURLWithPath: worktreeRoot).appendingPathComponent(path)
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

/// One batch of file texts read by `DiffService.fileTexts(for:headPaths:worktreePaths:)`,
/// each side keyed by the path it was requested under. A path with no entry has no
/// readable text.
///
/// Both sides are `var` so a consumer can take each text out as it uses it: the
/// batch holds up to `DiffHighlighter.maxHighlightBytes` per side per file, and
/// the highlight pass that reads it is serialized over many files, so entries left
/// in place stay alive for the whole pass.
struct DiffFileTexts: Sendable {
    var head: [String: String]
    var worktree: [String: String]
}
