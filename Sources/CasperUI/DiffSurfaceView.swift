import CasperCore
import CasperGit
import SwiftUI

/// Highlighted lines for one diff file, indexed by 1-based source line number.
/// `new` covers the working-tree side (additions + context); `old` covers the
/// HEAD side (deletions). Either may be nil when that side can't be highlighted.
private struct FileHighlight { var new: [AttributedString]?; var old: [AttributedString]? }

/// Read-only diff surface: the workspace's working tree vs HEAD, per-file, with
/// +/- line coloring. Refreshes on open and on the button.
struct DiffSurfaceView: View {
    @Bindable var model: AppModel
    let workspace: Workspace
    @Environment(\.colorScheme) private var colorScheme
    @State private var diff: GitDiff?
    @State private var loaded = false
    /// Syntax highlights keyed by `GitDiffFile.id`; populated progressively as
    /// each file finishes highlighting off the main actor. The stable key lets a
    /// rebuild carry over highlights for files whose diff hasn't changed.
    @State private var highlights: [String: FileHighlight] = [:]
    @State private var highlightTask: Task<Void, Never>?
    /// Top visible file across rebuilds, so a debounced refresh keeps scroll.
    @State private var scrolledFileID: String?
    /// Visible width of the content area, measured once laid out. Drives the
    /// full-bleed row/header backgrounds (see `DiffFileView`/`DiffLineRow`).
    @State private var contentWidth: CGFloat = 0
    /// Visible height of the content area. Lets a short diff fill the viewport so
    /// its files top-align instead of being vertically centered by the ScrollView.
    @State private var contentHeight: CGFloat = 0
    /// Natural (unpinned) height of the stacked files, measured so the vertical
    /// scroll axis is enabled only when the diff actually overflows the viewport.
    /// Without this, the horizontal scrollbar steals a strip of height and the
    /// full-height pin makes a short diff report a spurious vertical scrollbar.
    @State private var contentNaturalHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            // GeometryReader is greedy, so it anchors the content region to the
            // full available area (top-aligned file list) and hands us its width.
            GeometryReader { proxy in
                content
                    .onAppear { contentWidth = proxy.size.width; contentHeight = proxy.size.height }
                    .onChange(of: proxy.size) { _, size in
                        contentWidth = size.width
                        contentHeight = size.height
                    }
            }
        }
        .onAppear { if !loaded { refresh() } }
        .onChange(of: colorScheme) { _, _ in if diff != nil { startHighlighting() } }
        .onChange(of: model.diffRevision) { _, _ in refresh() }
        .onDisappear { highlightTask?.cancel() }
    }

    @ViewBuilder private var content: some View {
        if let diff {
            if diff.files.isEmpty {
                DiffEmptyState(
                    systemImage: "checkmark.circle", title: "No changes",
                    message: "The working tree matches HEAD.")
            } else {
                let scrollsVertically = contentNaturalHeight > contentHeight
                ScrollView(scrollsVertically ? [.vertical, .horizontal] : .horizontal) {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(diff.files) { file in
                            DiffFileView(
                                file: file, contentWidth: contentWidth, highlight: highlights[file.id])
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentNaturalHeight = $0 }
                    .frame(minWidth: contentWidth, minHeight: contentHeight, alignment: .topLeading)
                    .scrollTargetLayout()
                }
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
        diff = model.computeDiff(for: workspace)
        loaded = true
        startHighlighting(reusing: previousFiles, previousHighlights)
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
    /// valid within the same color scheme. Callers reacting to a color-scheme
    /// change pass no reuse args, forcing a full re-highlight (colors differ).
    private func startHighlighting(
        reusing previousFiles: [GitDiffFile] = [], _ previousHighlights: [String: FileHighlight] = [:]
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

        let dark = colorScheme == .dark
        highlightTask = Task {
            for file in files {
                if Task.isCancelled { return }
                guard !file.isBinary else { continue }
                if carried[file.id] != nil { continue }  // already have a valid highlight — skip

                let newText = model.worktreeFileText(for: workspace, path: file.newPath)
                let oldText = model.headFileText(for: workspace, path: file.oldPath)

                let newLines = await highlight(newText, path: file.newPath, dark: dark)
                let oldLines = await highlight(oldText, path: file.oldPath, dark: dark)
                if Task.isCancelled { return }

                highlights[file.id] = FileHighlight(new: newLines, old: oldLines)
            }
        }
    }

    /// Highlights one file's text, or returns nil when absent. The library trims
    /// trailing whitespace, so a single trailing newline is stripped first to
    /// keep its line count aligned with the source.
    private func highlight(_ text: String?, path: String, dark: Bool) async -> [AttributedString]? {
        guard let text else { return nil }
        let trimmed = text.hasSuffix("\n") ? String(text.dropLast()) : text
        return await DiffHighlighter.highlightedLines(of: trimmed, forPath: path, dark: dark)
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

private struct DiffFileView: View {
    let file: GitDiffFile
    let contentWidth: CGFloat
    let highlight: FileHighlight?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if file.isBinary {
                Text("Binary file")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
            } else {
                ForEach(visibleHunks) { entry in
                    Text(entry.hunk.header)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 8)
                        .padding(.top, 6).padding(.bottom, 2)
                    ForEach(Array(entry.hunk.lines.prefix(entry.lineCount).enumerated()), id: \.offset) { _, line in
                        DiffLineRow(
                            line: line, gutterWidth: gutterWidth, contentWidth: contentWidth,
                            highlighted: highlightedLine(for: line))
                    }
                }
                if hiddenLineCount > 0 {
                    Text("Diff too large — \(hiddenLineCount) more lines hidden")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                }
            }
        }
    }

    /// Per-file cap on rendered diff rows. A single pathologically large file
    /// (e.g. a generated lockfile) would otherwise instantiate every line row at
    /// once when it scrolls into the enclosing lazy stack; the overflow is
    /// summarized by `hiddenLineCount` instead.
    private static let maxRenderedLines = 3000

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

    /// Lines omitted by the per-file cap, for the truncation notice.
    private var hiddenLineCount: Int {
        let total = file.hunks.reduce(0) { $0 + $1.lines.count }
        return max(0, total - Self.maxRenderedLines)
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

    /// Full-bleed header band: file path + status on the left, the +N −N line
    /// summary pushed to the right, over a subtly elevated fill.
    private var header: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(.body, design: .monospaced)).bold()
            Text(file.status.rawValue).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Text("+\(insertions)").foregroundStyle(DiffLineStyle.insertionTint)
                Text("\u{2212}\(deletions)").foregroundStyle(DiffLineStyle.deletionTint)
            }
            .font(.callout.monospacedDigit().bold())
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(minWidth: contentWidth, alignment: .leading)
        .background(Color.secondary.opacity(0.12))
    }

    private var title: String {
        if file.oldPath.isEmpty { return file.newPath }
        if file.newPath.isEmpty { return file.oldPath }
        return file.oldPath == file.newPath
            ? file.newPath : "\(file.oldPath) → \(file.newPath)"
    }

    private var insertions: Int {
        file.hunks.flatMap(\.lines).filter { $0.kind == .addition }.count
    }

    private var deletions: Int {
        file.hunks.flatMap(\.lines).filter { $0.kind == .deletion }.count
    }

    /// Widest line number across the file's hunks, so the gutter never truncates
    /// (e.g. 5-digit line numbers in a large file).
    private var maxDigits: Int {
        let lines = file.hunks.flatMap(\.lines)
        let numbers = lines.flatMap { [$0.oldLineNumber, $0.newLineNumber] }.compactMap { $0 }
        let widest = numbers.max() ?? 0
        return max(String(widest).count, 1)
    }

    /// Two line numbers plus inter-number spacing, with a sensible minimum width.
    private var gutterWidth: CGFloat {
        max(CGFloat(maxDigits * 2 * 8 + 24), 60)
    }
}

private struct DiffLineRow: View {
    let line: GitDiffLine
    let gutterWidth: CGFloat
    let contentWidth: CGFloat
    let highlighted: AttributedString?

    var body: some View {
        HStack(spacing: 0) {
            // Leading accent stripe hugs the very left edge (clear for context).
            Rectangle()
                .fill(DiffLineStyle.accent(for: line.kind))
                .frame(width: 3)
            HStack(spacing: 8) {
                Text(gutter)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(width: gutterWidth, alignment: .trailing)
                codeText
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.leading, 8)
        }
        .frame(minWidth: contentWidth, alignment: .leading)
        .background(DiffLineStyle.background(for: line.kind))
    }

    /// The code column. When a highlight is available its runs carry their own
    /// syntax colors (fonts stripped, so the monospaced font above applies
    /// uniformly), prefixed by the neutral diff marker. Otherwise it falls back
    /// to plain text tinted by the line kind.
    @ViewBuilder private var codeText: some View {
        if let highlightedContent {
            Text(highlightedContent)
        } else {
            Text(DiffLineStyle.prefix(for: line.kind) + line.content)
                .foregroundStyle(DiffLineStyle.color(for: line.kind))
        }
    }

    /// The diff marker prepended to the highlighted content, or nil when there is
    /// no highlight to show. The marker inherits `.primary`; the appended runs
    /// keep their syntax colors.
    private var highlightedContent: AttributedString? {
        guard let highlighted else { return nil }
        var content = AttributedString(DiffLineStyle.prefix(for: line.kind))
        content.append(highlighted)
        return content
    }

    private var gutter: String {
        let old = line.oldLineNumber.map(String.init) ?? ""
        let new = line.newLineNumber.map(String.init) ?? ""
        return "\(old)  \(new)"
    }
}
