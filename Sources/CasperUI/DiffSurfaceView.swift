import CasperCore
import CasperGit
import SwiftUI

/// Read-only diff surface: the workspace's working tree vs HEAD, rendered as a
/// single TextKit document by `DiffTextSurface`.
///
/// This view orchestrates and nothing else — refresh, dedup, progressive syntax
/// highlighting, the scroll target and the empty states. Every pixel of the diff
/// itself is drawn by AppKit, so no per-line SwiftUI layout exists to feed back
/// into a refresh.
///
/// What to render travels down as a `DiffRendering` property, one way. The two
/// things that are events rather than state — a scroll target, a file's syntax
/// colors finishing — go through `controller` instead, which tolerates a surface
/// that isn't there yet and is retried until it is.
struct DiffSurfaceView: View {
    let model: AppModel
    let workspace: Workspace
    /// The last computed diff, kept so a refresh can recognise a byte-identical
    /// recompute and skip all content work.
    @State private var diff: GitDiff?
    @State private var loaded = false
    /// What the surface renders, built from `diff`. Handed to `DiffTextSurface`
    /// as a property so the first paint doesn't depend on the surface already
    /// existing when the refresh that produced it finishes — it usually does not.
    @State private var rendering: DiffRendering?
    /// Syntax highlights keyed by `GitDiffFile.id`, published to the surface as
    /// each file finishes. Bookkeeping only — `body` never reads it — so that a
    /// rebuild can carry highlights over and repaint them onto the fresh storage.
    @State private var highlightCache: [String: DiffFileHighlight] = [:]
    @State private var highlightTask: Task<Void, Never>?
    /// The in-flight `refresh()` compute, cancelled before starting a new one so a
    /// rapid sequence of `diffRevision` bumps can't assign results out of order.
    @State private var refreshTask: Task<Void, Never>?
    /// Nonce of the last `model.diffScrollTarget` this view acted on, so a target
    /// is applied once (not re-applied on every unrelated body re-evaluation).
    @State private var appliedScrollNonce = 0
    /// The handle onto the AppKit surface. Its coordinator stays nil until SwiftUI
    /// realizes the representable — one layout pass after the body that first
    /// shows it — so every call through it has to tolerate nil.
    @State private var controller = DiffSurfaceController()

    var body: some View {
        content
            // Reappearing with the state intact resumes highlighting instead of
            // recomputing the diff: `.onDisappear` cancelled the highlight task
            // wherever it had got to, and without this restart the files it had
            // not reached stay uncolored until the next `diffRevision` bump —
            // which on a quiet worktree never comes. Already-highlighted files
            // are skipped by `highlightCache`, so the resumed pass picks up
            // exactly where the cancelled one stopped.
            .onAppear { if loaded { startHighlighting() } else { refresh() } }
            .onChange(of: model.diffRevision) { _, _ in refresh() }
            .onChange(of: model.diffScrollTarget) { _, _ in applyPendingScroll() }
            // A target can name a file that only the freshly computed diff has, and
            // the surface only holds that diff once SwiftUI has pushed the new
            // `rendering` into it. This is the retry for that.
            .onChange(of: rendering?.revision) { _, _ in applyPendingScroll() }
            .onDisappear { highlightTask?.cancel(); refreshTask?.cancel() }
    }

    /// Branches on `rendering` rather than on `diff`: the two are assigned
    /// together and a document exists for exactly the diffs that exist, so keying
    /// on the value the surface actually needs leaves no unreachable branch.
    ///
    /// `loaded` gates the two failure states, because `rendering` is nil both
    /// before and after a failed refresh. SwiftUI evaluates `body` before
    /// `.onAppear` runs `refresh()`, and `refresh()` suspends immediately on the
    /// detached libgit2 walk — so without this branch the first frame of a
    /// Git-backed workspace reads "Couldn't compute the diff", and does so again
    /// on every expand of the Diff tab (collapsing unmounts the view and discards
    /// the state). Blank rather than a spinner: the wait is usually a few frames,
    /// and anything animated would flicker.
    @ViewBuilder private var content: some View {
        if let rendering {
            if rendering.document.files.isEmpty {
                DiffEmptyState(
                    systemImage: "checkmark.circle", title: "No changes",
                    message: "The working tree matches HEAD.")
            } else {
                DiffTextSurface(controller: controller, rendering: rendering)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // The document is already in, pushed by the representable's own
                    // update. A scroll target waiting on the surface is not: it goes
                    // through the coordinator, which is created only when SwiftUI
                    // realizes the representable, so this is where a target that
                    // arrived before the surface catches up.
                    .onAppear { applyPendingScroll() }
            }
        } else if !loaded {
            Color.clear
        } else if model.isWorkspaceGitBacked(workspace) {
            DiffEmptyState(
                systemImage: "exclamationmark.triangle", title: "Couldn't compute the diff",
                message: "The repository couldn't be read.")
        } else {
            DiffEmptyState(
                systemImage: "doc.text.magnifyingglass", title: "No diff",
                message: "This workspace has no Git repository.")
        }
    }

    private func refresh() {
        let previousFiles = diff?.files ?? []
        let started = Date()
        // Keep the previous `diff` on screen while the async compute runs (no blank
        // flash): `content` shows the last value until it's reassigned below.
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            let newDiff = await model.diffService.computeDiff(for: workspace)
            if Task.isCancelled { return }
            // Dedup redundant refreshes: on an active worktree an FSEvents watcher
            // bumps `model.diffRevision` very frequently, and many bumps recompute a
            // byte-identical diff. Rebuilding the document and swapping the whole
            // text storage for an unchanged diff is pure waste, and it would drop
            // the reader's selection along the way. On an unchanged diff, skip all
            // content work; only a pending scroll target (which can arrive
            // independent of a content change) still needs applying.
            if loaded, newDiff == diff {
                applyPendingScroll()
                return
            }
            let newDocument = await Self.makeDocument(for: newDiff)
            if Task.isCancelled { return }
            diff = newDiff
            // Read here rather than before the awaits above: the previous
            // highlight task keeps publishing into the cache until
            // `startHighlighting()` cancels it below, and a snapshot taken
            // ahead of the compute would miss everything it finished in the
            // meantime — sending those files back through the highlighter for
            // colors that were already computed.
            let previousHighlights = highlightCache
            highlightCache = Self.carriedHighlights(
                for: newDiff?.files ?? [], from: previousFiles, previousHighlights)
            // Restarting the count when the diff disappears is safe: that tears the
            // surface down with it, so the next revision 1 meets a fresh
            // coordinator that has applied nothing.
            let revision = (rendering?.revision ?? 0) + 1
            rendering = newDocument.map {
                DiffRendering(revision: revision, document: $0, highlights: highlightCache)
            }
            let computeMs = Int(Date().timeIntervalSince(started) * 1000)
            logDiffShape(of: newDocument, computeMs: computeMs)
            loaded = true
            startHighlighting()
        }
    }

    /// Flattening a diff into the renderer's model walks every line of every file,
    /// so it runs off the main actor; `DiffDocument` is `Sendable` and crosses
    /// back.
    private static func makeDocument(for diff: GitDiff?) async -> DiffDocument? {
        guard let diff else { return nil }
        return await Task.detached(priority: .userInitiated) { DiffDocument(diff: diff) }.value
    }

    /// Logs the freshly computed diff's shape so a diff-view freeze is
    /// diagnosable from the last line before the hang: the culprit is usually a
    /// file with a huge single line (`maxLineLen`, e.g. a minified bundle).
    ///
    /// The numbers come from `DiffDocument.shape`, accumulated while the document
    /// was built off the main actor: measuring them here would walk the whole
    /// diff a third time, on the main actor, on a path an FSEvents watcher drives
    /// — counting the characters of the very lines it exists to report on.
    private func logDiffShape(of document: DiffDocument?, computeMs: Int) {
        guard let document, !document.files.isEmpty else { return }
        let shape = document.shape
        CasperLog.app.notice(
            """
            diff refresh: files=\(document.files.count, privacy: .public) \
            lines=\(shape.totalLines, privacy: .public) \
            maxFileLines=\(shape.maxFileLines, privacy: .public) \
            maxLineLen=\(shape.maxLineLen, privacy: .public) \
            computeMs=\(computeMs, privacy: .public)
            """)
    }

    /// Apply a pending `model.diffScrollTarget` for this workspace once its file
    /// exists in the loaded diff. Idempotent via `appliedScrollNonce`, so it can
    /// be called both when the target changes and when the diff finishes loading.
    ///
    /// The nonce is consumed only once the surface has actually scrolled, so a
    /// target that arrives before the surface is realized — or before the document
    /// holding its file has reached it — is applied by a later call rather than
    /// being silently swallowed.
    private func applyPendingScroll() {
        guard let coordinator = controller.coordinator,
              let target = model.diffScrollTarget,
              target.workspaceID == workspace.id,
              target.nonce != appliedScrollNonce,
              let files = diff?.files,
              let matchID = DiffFileMatch.match(target.file, in: files) else { return }
        guard coordinator.scroll(toFileID: matchID) else { return }
        appliedScrollNonce = target.nonce
    }

    /// The highlights that survive a rebuild.
    ///
    /// A file whose `GitDiffFile` value is unchanged has byte-identical hunks vs
    /// HEAD, which for the working-tree diff implies the text that was highlighted
    /// is unchanged too — so its existing highlight is still valid and re-running
    /// the highlighter over it is pure waste.
    private static func carriedHighlights(
        for files: [GitDiffFile], from previousFiles: [GitDiffFile],
        _ previousHighlights: [String: DiffFileHighlight]
    ) -> [String: DiffFileHighlight] {
        // Index the previous diff by file id so an unchanged file is a lookup
        // rather than a scan.
        let previousByID = Dictionary(previousFiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var carried: [String: DiffFileHighlight] = [:]
        for file in files {
            if let previous = previousByID[file.id], previous == file,
               let existing = previousHighlights[file.id] {
                carried[file.id] = existing
            }
        }
        return carried
    }

    /// Kicks off a background pass that highlights each file's working-tree and
    /// HEAD text — as far as the document renders lines of either — publishing
    /// results per file so colors appear as they finish.
    /// Neither the reads nor the highlighting touch the main actor: both sides of
    /// every file are read in one detached pass over a single `Repository`
    /// (`DiffService.fileTexts`), which also caps them at
    /// `DiffHighlighter.maxHighlightBytes`.
    ///
    /// Files already in `highlightCache` were carried over from the previous diff
    /// and are skipped.
    private func startHighlighting() {
        highlightTask?.cancel()
        // `diff` and `rendering` are assigned together in `refresh()`, so either
        // both are there or neither is; with no document there is nothing to
        // paint and nothing worth keeping in the cache.
        guard let files = diff?.files, let document = rendering?.document else {
            highlightCache = [:]
            return
        }
        let carried = highlightCache
        // Resolved once, and used for both what to read and what to loop over, so
        // the two can't disagree. The index rides along because
        // `prunedToRenderedLines(ofFileAt:in:)` needs the file's place in the
        // document.
        let pending = files.enumerated()
            .filter { !$0.element.isBinary && carried[$0.element.id] == nil }
            .map { (fileIndex: $0.offset, file: $0.element) }

        // Only the sides the document renders lines of are read. Pruning discards
        // the whole of a side that renders none — the HEAD side of an append-only
        // change, either side of a file the line budgets cut entirely — so reading
        // its blob and highlighting it produces nothing that survives.
        var headPaths: [String] = []
        var worktreePaths: [String] = []
        for (fileIndex, file) in pending {
            let rendered = document.renderedLineNumbers(ofFileAt: fileIndex)
            if !rendered.old.isEmpty { headPaths.append(file.oldPath) }
            if !rendered.new.isEmpty { worktreePaths.append(file.newPath) }
        }

        highlightTask = Task {
            var texts = await model.diffService.fileTexts(
                for: workspace, headPaths: headPaths, worktreePaths: worktreePaths)
            if Task.isCancelled { return }

            for (fileIndex, file) in pending {
                if Task.isCancelled { return }
                // Taken out of the batch rather than read from it: the loop is
                // serialized over every file, and a text left behind stays alive
                // until the last of them is done.
                let newText = texts.worktree.removeValue(forKey: file.newPath)
                let oldText = texts.head.removeValue(forKey: file.oldPath)

                let newLines = await highlight(newText, path: file.newPath)
                let oldLines = await highlight(oldText, path: file.oldPath)
                if Task.isCancelled { return }

                // Published per file (rather than batched) so coloring still appears
                // progressively as each file finishes. It goes straight into the live
                // text storage; the cache copy is only there to carry it over to the
                // next rebuild.
                //
                // Pruned before either of them sees it: the highlighter colors
                // the whole file, and holding those thousands of unrendered
                // lines is this renderer's largest avoidable allocation (see
                // `DiffFileHighlight.prunedToRenderedLines(ofFileAt:in:)`).
                // `pending`'s indices are positions in the document's own file
                // list, so they line up.
                let fileHighlight = DiffFileHighlight(new: newLines, old: oldLines)
                    .prunedToRenderedLines(ofFileAt: fileIndex, in: document)
                highlightCache[file.id] = fileHighlight
                controller.coordinator?.applyHighlight(fileHighlight, forFileID: file.id)
            }
        }
    }

    /// Highlights one file's text, or returns nil when absent. The library trims
    /// trailing whitespace, so a single trailing newline is stripped first to
    /// keep its line count aligned with the source.
    private func highlight(_ text: String?, path: String) async -> [AttributedString]? {
        guard let text else { return nil }
        let trimmed = text.hasSuffix("\n") ? String(text.dropLast()) : text
        return await DiffHighlighter.highlightedLines(of: trimmed, forPath: path)
    }
}

/// The diff surface's compact, centered empty/error state. Replaces
/// ContentUnavailableView, which renders too tall and top-anchored in this
/// narrow inspector panel.
private struct DiffEmptyState: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
