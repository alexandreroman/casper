import CasperCore
import CasperGit
import SwiftUI

/// Highlighted lines for one diff file, indexed by 1-based source line number.
/// `new` covers the working-tree side (additions + context); `old` covers the
/// HEAD side (deletions). Either may be nil when that side can't be highlighted.
///
/// A reference type with identity equality: publishing one file's highlight
/// swaps in a new instance for that file only, so SwiftUI's `.equatable()`
/// comparison stays O(1) (an `===` check) instead of deep-comparing the
/// attributed-string arrays of every realized file on every per-file publish.
private final class FileHighlight: Equatable {
    let new: [AttributedString]?
    let old: [AttributedString]?

    init(new: [AttributedString]?, old: [AttributedString]?) {
        self.new = new
        self.old = old
    }

    static func == (lhs: FileHighlight, rhs: FileHighlight) -> Bool { lhs === rhs }
}

/// Per-file metrics precomputed once when the diff changes, so `body` never
/// walks a file's lines to render its header stats or gutter. Equatable (all
/// stored fields are), which lets `DiffFileView` be compared cheaply by value.
private struct DiffFileMetrics: Equatable {
    let insertions: Int
    let deletions: Int
    let gutterWidth: CGFloat
    let hiddenLineCount: Int

    init(file: GitDiffFile) {
        var insertions = 0
        var deletions = 0
        var totalLines = 0
        var widestLineNumber = 0
        for hunk in file.hunks {
            for line in hunk.lines {
                totalLines += 1
                switch line.kind {
                case .addition: insertions += 1
                case .deletion: deletions += 1
                case .context: break
                }
                if let old = line.oldLineNumber { widestLineNumber = max(widestLineNumber, old) }
                if let new = line.newLineNumber { widestLineNumber = max(widestLineNumber, new) }
            }
        }
        self.insertions = insertions
        self.deletions = deletions
        // Widest line number sets the gutter width so it never truncates (e.g.
        // 5-digit line numbers in a large file); one line number plus trailing
        // padding, with a sensible minimum.
        let maxDigits = max(String(widestLineNumber).count, 1)
        self.gutterWidth = max(CGFloat(maxDigits * 9 + 12), 36)
        self.hiddenLineCount = max(0, totalLines - DiffFileView.maxRenderedLines)
    }
}

/// Read-only diff surface: the workspace's working tree vs HEAD, per-file, with
/// +/- line coloring. Refreshes on open and on the button. Long code lines wrap
/// rather than requiring horizontal scrolling.
struct DiffSurfaceView: View {
    let model: AppModel
    let workspace: Workspace
    @State private var diff: GitDiff?
    @State private var loaded = false
    /// Syntax highlights keyed by `GitDiffFile.id`; populated progressively as
    /// each file finishes highlighting off the main actor. The stable key lets a
    /// rebuild carry over highlights for files whose diff hasn't changed.
    @State private var highlights: [String: FileHighlight] = [:]
    /// Per-file metrics (line stats, gutter width, hidden-line count) keyed by
    /// `GitDiffFile.id`, rebuilt once whenever `diff` is (re)assigned so `body`
    /// never recomputes O(lines) values while rendering.
    @State private var metrics: [String: DiffFileMetrics] = [:]
    @State private var highlightTask: Task<Void, Never>?
    /// The in-flight `refresh()` compute, cancelled before starting a new one so a
    /// rapid sequence of `diffRevision` bumps can't assign results out of order.
    @State private var refreshTask: Task<Void, Never>?
    /// Top visible file across rebuilds, so a debounced refresh keeps scroll.
    @State private var scrolledFileID: String?
    /// Nonce of the last `model.diffScrollTarget` this view acted on, so a target
    /// is applied once (not re-applied on every unrelated body re-evaluation).
    @State private var appliedScrollNonce = 0

    var body: some View {
        content
            .onAppear { if !loaded { refresh() } }
            .onChange(of: model.diffRevision) { _, _ in refresh() }
            .onChange(of: model.diffScrollTarget) { _, _ in applyPendingScroll() }
            .onDisappear { highlightTask?.cancel(); refreshTask?.cancel() }
    }

    @ViewBuilder private var content: some View {
        if let diff {
            if diff.files.isEmpty {
                DiffEmptyState(
                    systemImage: "checkmark.circle", title: "No changes",
                    message: "The working tree matches HEAD.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(diff.files) { file in
                            let fileMetrics = metrics[file.id] ?? DiffFileMetrics(file: file)
                            Section {
                                DiffFileView(
                                    file: file, highlight: highlights[file.id],
                                    metrics: fileMetrics,
                                    isLastFile: file.id == diff.files.last?.id)
                                    .equatable()
                            } header: {
                                DiffFileHeaderBar(file: file, metrics: fileMetrics)
                            }
                        }
                    }
                    .padding(.bottom, 24)
                    .scrollTargetLayout()
                }
                .defaultScrollAnchor(.top)
                .scrollPosition(id: $scrolledFileID, anchor: .top)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
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
        let previousHighlights = highlights
        let started = Date()
        // Keep the previous `diff` on screen while the async compute runs (no blank
        // flash): `content` shows the last value until it's reassigned below.
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            let newDiff = await model.computeDiff(for: workspace)
            if Task.isCancelled { return }
            diff = newDiff
            // Precompute per-file metrics once here (off the render hot path),
            // keyed by file id so `body` can look them up in O(1).
            metrics = Dictionary(uniqueKeysWithValues: (diff?.files ?? []).map { ($0.id, DiffFileMetrics(file: $0)) })
            let computeMs = Int(Date().timeIntervalSince(started) * 1000)
            logDiffShape(computeMs: computeMs)
            applyPendingScroll()
            loaded = true
            startHighlighting(reusing: previousFiles, previousHighlights)
        }
    }

    /// Logs the freshly computed diff's shape so a diff-view freeze is
    /// diagnosable from the last line before the hang: the culprit is usually a
    /// file with a huge single line (`maxLineLen`, e.g. a minified bundle).
    /// Computed with plain loops to avoid materializing every line of a large
    /// diff into intermediate arrays.
    private func logDiffShape(computeMs: Int) {
        guard let diff, !diff.files.isEmpty else { return }
        var totalLines = 0
        var maxFileLines = 0
        var maxLineLen = 0
        for file in diff.files {
            var fileLines = 0
            for hunk in file.hunks {
                fileLines += hunk.lines.count
                for line in hunk.lines {
                    maxLineLen = max(maxLineLen, line.content.count)
                }
            }
            totalLines += fileLines
            maxFileLines = max(maxFileLines, fileLines)
        }
        CasperLog.app.notice(
            """
            diff refresh: files=\(diff.files.count, privacy: .public) \
            lines=\(totalLines, privacy: .public) \
            maxFileLines=\(maxFileLines, privacy: .public) \
            maxLineLen=\(maxLineLen, privacy: .public) \
            computeMs=\(computeMs, privacy: .public)
            """)
    }

    /// Apply a pending `model.diffScrollTarget` for this workspace once its file
    /// exists in the loaded diff. Idempotent via `appliedScrollNonce`, so it can
    /// be called both when the target changes and when the diff finishes loading.
    private func applyPendingScroll() {
        guard let target = model.diffScrollTarget,
              target.workspaceID == workspace.id,
              target.nonce != appliedScrollNonce,
              let files = diff?.files,
              let matchID = DiffFileMatch.match(target.file, in: files) else { return }
        appliedScrollNonce = target.nonce
        // Defer one runloop so the ScrollView has laid the target file out before
        // we drive its scroll position.
        DispatchQueue.main.async { scrolledFileID = matchID }
    }

    /// Kicks off a background pass that highlights each file's working-tree and
    /// HEAD text, publishing results per file so colors appear as they finish.
    /// File reads stay on the main actor (quick, size-capped); only the actual
    /// highlighting suspends off-actor, keeping the UI responsive.
    ///
    /// When the previous diff and its highlights are handed in, files whose
    /// `GitDiffFile` value is unchanged keep their existing `FileHighlight`
    /// instead of being re-highlighted: value-equality means the file's hunks
    /// vs HEAD are byte-identical, which for the working-tree diff implies the
    /// text used for highlighting is unchanged, so its cached highlight is still
    /// valid.
    private func startHighlighting(
        reusing previousFiles: [GitDiffFile], _ previousHighlights: [String: FileHighlight]
    ) {
        highlightTask?.cancel()
        guard let files = diff?.files else { highlights = [:]; return }

        // Index the previous diff by file id so we can carry over highlights for
        // files whose diff is byte-identical, skipping a redundant re-highlight.
        let previousByID = Dictionary(previousFiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var carried: [String: FileHighlight] = [:]
        for file in files {
            if let old = previousByID[file.id], old == file, let existing = previousHighlights[file.id] {
                carried[file.id] = existing
            }
        }
        highlights = carried

        highlightTask = Task {
            for file in files {
                if Task.isCancelled { return }
                guard !file.isBinary else { continue }
                if carried[file.id] != nil { continue }  // already have a valid highlight — skip

                let newText = model.worktreeFileText(for: workspace, path: file.newPath)
                let oldText = model.headFileText(for: workspace, path: file.oldPath)

                let newLines = await highlight(newText, path: file.newPath)
                let oldLines = await highlight(oldText, path: file.oldPath)
                if Task.isCancelled { return }

                highlights[file.id] = FileHighlight(new: newLines, old: oldLines)
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

/// Per-file header band, used as each file's pinned `Section` header (see
/// `pinnedViews: [.sectionHeaders]` in `DiffSurfaceView.content`): file path +
/// status on the left, the +N −N line summary pushed to the right via a
/// flexible spacer, sized to the diff panel's own width (`maxWidth: .infinity`)
/// since there's no horizontal scrolling to diverge from. A 1pt hairline marks
/// its bottom edge against the file content scrolling underneath it.
private struct DiffFileHeaderBar: View {
    let file: GitDiffFile
    let metrics: DiffFileMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(title).font(.system(.body, design: .monospaced)).bold()
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(file.status.rawValue).font(.caption).foregroundStyle(.secondary)
                    .fixedSize()
                HStack(spacing: 8) {
                    Text("+\(metrics.insertions)").foregroundStyle(DiffLineStyle.insertionTint)
                    Text("\u{2212}\(metrics.deletions)").foregroundStyle(DiffLineStyle.deletionTint)
                }
                .font(.callout.monospacedDigit().bold())
                .fixedSize()
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.12))
            .background(Color(nsColor: .windowBackgroundColor))
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
        }
    }

    private var title: String {
        if file.oldPath.isEmpty { return file.newPath }
        if file.newPath.isEmpty { return file.oldPath }
        return file.oldPath == file.newPath
            ? file.newPath : "\(file.oldPath) → \(file.newPath)"
    }
}

private struct DiffFileView: View, @MainActor Equatable {
    let file: GitDiffFile
    let highlight: FileHighlight?
    /// Precomputed line stats, gutter width, and hidden-line count for this file.
    let metrics: DiffFileMetrics
    /// True for the diff's last file, so its trailing gap isn't doubled up
    /// with the outer scroll content's own bottom padding.
    let isLastFile: Bool

    var body: some View {
        // A plain VStack, not a nested LazyVStack: a lazy stack nested as a
        // Section's content inside the outer LazyVStack/ScrollView can't report
        // an exact height, so it over-reserves vertical space and leaves large
        // empty gaps between files. The outer LazyVStack still virtualizes at
        // the per-file level, and `maxRenderedLines` caps how many rows a
        // realized file lays out.
        VStack(alignment: .leading, spacing: 0) {
            if file.isBinary {
                Text("Binary file")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(visibleHunks) { entry in
                    Text(entry.hunk.header)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.top, 6).padding(.bottom, 2)
                    ForEach(Array(entry.hunk.lines.prefix(entry.lineCount).enumerated()), id: \.offset) { _, line in
                        DiffLineRow(
                            line: line, gutterWidth: metrics.gutterWidth,
                            highlighted: highlightedLine(for: line))
                    }
                }
                if metrics.hiddenLineCount > 0 {
                    Text("Diff too large — \(metrics.hiddenLineCount) more lines hidden")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                }
            }
        }
        .padding(.bottom, isLastFile ? 0 : 14)
    }

    /// Per-file cap on rendered diff rows. A single pathologically large file
    /// (e.g. a generated lockfile) would otherwise instantiate every line row at
    /// once when it scrolls into the enclosing lazy stack; the overflow is
    /// summarized by `hiddenLineCount` instead.
    nonisolated fileprivate static let maxRenderedLines = 3000

    /// One rendered hunk, trimmed to the leading `lineCount` lines that still fit
    /// under `maxRenderedLines`. Hunks past the cap are dropped entirely.
    private struct VisibleHunk: Identifiable {
        let id: Int  // hunk offset within the file
        let hunk: GitDiffHunk
        let lineCount: Int
    }

    /// The file's hunks distributed across the per-file line budget, in order.
    private var visibleHunks: [VisibleHunk] {
        var remaining = Self.maxRenderedLines
        var result: [VisibleHunk] = []
        for (offset, hunk) in file.hunks.enumerated() {
            guard remaining > 0 else { break }
            let count = min(hunk.lines.count, remaining)
            result.append(VisibleHunk(id: offset, hunk: hunk, lineCount: count))
            remaining -= count
        }
        return result
    }

    /// The highlighted attributed text for a line, or nil when unavailable.
    /// Deletions read from the HEAD side, additions and context from the
    /// working-tree side, both indexed by their 1-based source line number.
    private func highlightedLine(for line: GitDiffLine) -> AttributedString? {
        switch line.kind {
        case .deletion:
            return lookup(highlight?.old, at: line.oldLineNumber)
        case .addition, .context:
            return lookup(highlight?.new, at: line.newLineNumber)
        }
    }

    private func lookup(_ lines: [AttributedString]?, at number: Int?) -> AttributedString? {
        guard let lines, let number, number >= 1, number <= lines.count else { return nil }
        return lines[number - 1]
    }
}

private struct DiffLineRow: View {
    let line: GitDiffLine
    let gutterWidth: CGFloat
    let highlighted: AttributedString?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Leading accent stripe hugs the very left edge (clear for context).
            Rectangle()
                .fill(DiffLineStyle.accent(for: line.kind))
                .frame(width: 3)
            HStack(alignment: .top, spacing: 8) {
                Text(DiffLineStyle.lineNumber(for: line).map(String.init) ?? "")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(numberColor)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(width: gutterWidth, alignment: .trailing)
                codeText
                    .font(.system(size: 14, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DiffLineStyle.background(for: line.kind))
    }

    /// Context lines keep the neutral gray gutter; changed lines pick up the
    /// same accent as the stripe, matching Claude Code's tinted line numbers.
    /// A concrete `Color` in both cases, avoiding a per-pass `AnyShapeStyle`.
    private var numberColor: Color {
        line.kind == .context ? DiffLineStyle.contextNumberTint : DiffLineStyle.accent(for: line.kind)
    }

    /// The code column. When a highlight is available its runs carry their own
    /// syntax colors (fonts stripped, so the monospaced font above applies
    /// uniformly); the prefixed diff marker is tinted with the line's accent
    /// color regardless of highlight availability. Falls back to plain text
    /// with a uniform `.primary` foreground for the code when there is no
    /// highlight. Wraps naturally instead of requiring horizontal scrolling.
    @ViewBuilder private var codeText: some View {
        let display = DiffLineStyle.truncatedForDisplay(line.content)
        if display.truncated {
            // Pathological single line (minified bundle, one-line lockfile, inlined
            // base64): render a capped slice + marker and skip highlight, so TextKit
            // never wraps a multi-megabyte string on the main thread — the diff-view
            // freeze this guards against.
            Text(DiffLineStyle.prefix(for: line.kind)).foregroundStyle(DiffLineStyle.accent(for: line.kind))
                + Text(display.text).foregroundStyle(Color.primary)
                + Text("  … (line truncated)").foregroundStyle(.secondary)
        } else if let highlightedContent {
            Text(highlightedContent)
        } else {
            Text(DiffLineStyle.prefix(for: line.kind)).foregroundStyle(DiffLineStyle.accent(for: line.kind))
                + Text(line.content).foregroundStyle(Color.primary)
        }
    }

    /// The diff marker prepended to the highlighted content, tinted with the
    /// line's accent color; the appended runs keep their syntax colors.
    private var highlightedContent: AttributedString? {
        guard let highlighted else { return nil }
        var prefix = AttributedString(DiffLineStyle.prefix(for: line.kind))
        prefix.foregroundColor = DiffLineStyle.accent(for: line.kind)
        prefix.append(highlighted)
        return prefix
    }
}
