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
            content
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
                            DiffFileView(file: file)
                        }
                    }
                    .padding(8)
                }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(title).font(.system(.body, design: .monospaced)).bold()
                Text(file.status.rawValue).font(.caption).foregroundStyle(.secondary)
            }
            if file.isBinary {
                Text("Binary file").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(file.hunks.enumerated()), id: \.offset) { _, hunk in
                    Text(hunk.header)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                        DiffLineRow(line: line, gutterWidth: gutterWidth)
                    }
                }
            }
        }
    }

    private var title: String {
        if file.oldPath.isEmpty { return file.newPath }
        if file.newPath.isEmpty { return file.oldPath }
        return file.oldPath == file.newPath
            ? file.newPath : "\(file.oldPath) → \(file.newPath)"
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

    var body: some View {
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
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DiffLineStyle.background(for: line.kind))
    }

    private var gutter: String {
        let old = line.oldLineNumber.map(String.init) ?? ""
        let new = line.newLineNumber.map(String.init) ?? ""
        return "\(old)  \(new)"
    }
}
