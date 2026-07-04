import CasperCore
import CasperGit
import SwiftUI

/// Read-only diff surface: the workspace's working tree vs HEAD, per-file, with
/// +/- line coloring. Refreshes on open and on the button.
struct DiffSurfaceView: View {
    @Bindable var model: AppModel
    let workspace: Workspace
    @State private var diff: GitDiff?
    @State private var loaded = false
    /// Visible width of the content area, measured once laid out. Drives the
    /// full-bleed row/header backgrounds (see `DiffFileView`/`DiffLineRow`).
    @State private var contentWidth: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Changes").font(.headline)
                Spacer()
                Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh")
            }
            .padding(6)
            Divider()
            // GeometryReader is greedy, so it anchors the content region to the
            // full available area (top-aligned file list) and hands us its width.
            GeometryReader { proxy in
                content
                    .onAppear { contentWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in contentWidth = width }
            }
        }
        .onAppear { if !loaded { refresh() } }
    }

    @ViewBuilder private var content: some View {
        if let diff {
            if diff.files.isEmpty {
                ContentUnavailableView(
                    "No changes", systemImage: "checkmark.circle",
                    description: Text("The working tree matches HEAD."))
            } else {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(diff.files.enumerated()), id: \.offset) { _, file in
                            DiffFileView(file: file, contentWidth: contentWidth)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        } else if model.isWorkspaceGitBacked(workspace) {
            ContentUnavailableView(
                "Couldn't compute the diff", systemImage: "exclamationmark.triangle",
                description: Text("The repository couldn't be read."))
        } else {
            ContentUnavailableView(
                "No diff", systemImage: "doc.text.magnifyingglass",
                description: Text("This workspace has no Git repository."))
        }
    }

    private func refresh() {
        diff = model.computeDiff(for: workspace)
        loaded = true
    }
}

private struct DiffFileView: View {
    let file: GitDiffFile
    let contentWidth: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if file.isBinary {
                Text("Binary file")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
            } else {
                ForEach(Array(file.hunks.enumerated()), id: \.offset) { _, hunk in
                    Text(hunk.header)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 8)
                        .padding(.top, 6).padding(.bottom, 2)
                    ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                        DiffLineRow(line: line, gutterWidth: gutterWidth, contentWidth: contentWidth)
                    }
                }
            }
        }
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
                Text(DiffLineStyle.prefix(for: line.kind) + line.content)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(DiffLineStyle.color(for: line.kind))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.leading, 8)
        }
        .frame(minWidth: contentWidth, alignment: .leading)
        .background(DiffLineStyle.background(for: line.kind))
    }

    private var gutter: String {
        let old = line.oldLineNumber.map(String.init) ?? ""
        let new = line.newLineNumber.map(String.init) ?? ""
        return "\(old)  \(new)"
    }
}
