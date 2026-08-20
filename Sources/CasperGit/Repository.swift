import Clibgit2
import Foundation

/// A libgit2 repository handle. Owns the `git_repository*` and frees it on
/// deinit. Not `Sendable`: use from a single thread/actor.
public final class Repository {
    let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        git_repository_free(pointer)
    }

    /// Initialize a new non-bare repository at `path` (creating it if needed).
    public static func initialize(atPath path: String) throws -> Repository {
        Libgit2.ensureInit()
        var repo: OpaquePointer?
        try gitCheck(git_repository_init(&repo, path, 0))
        return Repository(pointer: try requireNonNull(repo, "repository"))
    }

    /// Open the repository at `path` (either a working directory or a `.git`
    /// directory). Does not search parent directories.
    public static func open(atPath path: String) throws -> Repository {
        Libgit2.ensureInit()
        var repo: OpaquePointer?
        try gitCheck(git_repository_open(&repo, path))
        return Repository(pointer: try requireNonNull(repo, "repository"))
    }

    /// Absolute path to the `.git` directory (trailing slash, per libgit2).
    public var gitDirPath: String {
        String(cString: git_repository_path(pointer))
    }

    /// Absolute path to the working directory, or nil for a bare repository.
    public var workdirPath: String? {
        guard let cString = git_repository_workdir(pointer) else { return nil }
        return String(cString: cString)
    }

    /// Absolute path to the repository's **common** directory (trailing slash, per
    /// libgit2): the `.git` directory shared by the main working tree and every
    /// linked worktree. Equal to `gitDirPath` when the handle is the main working
    /// tree; for a linked worktree `gitDirPath` is `<common>/worktrees/<name>/`
    /// while this stays `<common>/`. It therefore identifies the repository
    /// itself, whichever of its working trees was opened.
    public var commonDirPath: String {
        String(cString: git_repository_commondir(pointer))
    }

    /// True when this handle was opened on a linked worktree (`git worktree add`)
    /// rather than on the repository's main working tree.
    public var isLinkedWorktree: Bool {
        git_repository_is_worktree(pointer) == 1
    }

    /// Short name of the branch HEAD currently points to.
    public func headBranchName() throws -> String {
        var head: OpaquePointer?
        let rc = git_repository_head(&head, pointer)
        if rc == GIT_EUNBORNBRANCH.rawValue {
            // Freshly-initialized repo with no commits: HEAD is a symbolic
            // reference (e.g. refs/heads/main). Resolve the branch name from
            // its symbolic target so promotion after `git init` shows the
            // real branch instead of falling back to the folder name.
            var ref: OpaquePointer?
            try gitCheck(git_reference_lookup(&ref, pointer, "HEAD"))
            defer { git_reference_free(ref) }
            guard let target = git_reference_symbolic_target(ref) else {
                throw GitError(code: -1, message: "unborn HEAD has no symbolic target")
            }
            let full = String(cString: target)  // e.g. "refs/heads/main"
            let prefix = "refs/heads/"
            return full.hasPrefix(prefix) ? String(full.dropFirst(prefix.count)) : full
        }
        try gitCheck(rc)
        defer { git_reference_free(head) }
        guard let shorthand = git_reference_shorthand(head) else {
            throw GitError(code: -1, message: "HEAD has no shorthand name")
        }
        return String(cString: shorthand)
    }

    /// Look up local branch `name` and run `body` with its resolved reference,
    /// freeing the reference afterward. Returns `ifMissing` when the branch does
    /// not exist. The reference is valid only for the duration of `body`.
    private func withLocalBranch<T>(
        _ name: String, ifMissing: T, _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        var ref: OpaquePointer?
        let code = git_branch_lookup(&ref, pointer, name, GIT_BRANCH_LOCAL)
        defer { git_reference_free(ref) }
        if code == GIT_ENOTFOUND.rawValue { return ifMissing }
        try gitCheck(code)
        return try body(try requireNonNull(ref, "branch reference"))
    }

    /// Whether a local branch named `name` exists.
    public func branchExists(_ name: String) throws -> Bool {
        try withLocalBranch(name, ifMissing: false) { _ in true }
    }

    /// Delete the local branch `name`. A missing branch is a no-op (idempotent).
    public func deleteBranch(_ name: String) throws {
        try withLocalBranch(name, ifMissing: ()) { ref in
            try gitCheck(git_branch_delete(ref))
        }
    }

    /// Whether local branch `name` is checked out in any working tree. Returns
    /// false if the branch does not exist.
    public func isBranchCheckedOut(_ name: String) throws -> Bool {
        try withLocalBranch(name, ifMissing: false) { ref in
            let rc = git_branch_is_checked_out(ref)
            if rc < 0 { try gitCheck(rc) }
            return rc == 1
        }
    }

    /// Whether the working tree and index are clean (no changes, no untracked).
    public func isClean() throws -> Bool {
        // Guarded: status mmaps live working-directory files to hash them (SIGBUS risk). See SigbusGuard.
        try SigbusGuard.run { [self] in
        var options = git_status_options()
        try gitCheck(git_status_options_init(
            &options, UInt32(GIT_STATUS_OPTIONS_VERSION)))
        options.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR
        options.flags =
            GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue
            | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS.rawValue

        var list: OpaquePointer?
        try gitCheck(git_status_list_new(&list, pointer, &options))
        defer { git_status_list_free(list) }

        return git_status_list_entrycount(list) == 0
        }
    }

    /// Whether `path` (relative to the working directory) is ignored per Git's own
    /// ignore rules — `.gitignore` at any level, `core.excludesFile`, and
    /// `.git/info/exclude` — evaluated by libgit2 (`git_ignore_path_is_ignored`).
    /// No manual `.gitignore` parsing.
    public func isPathIgnored(_ path: String) throws -> Bool {
        var ignored: Int32 = 0
        try gitCheck(git_ignore_path_is_ignored(&ignored, pointer, path))
        return ignored != 0
    }

    /// Absolute paths of the working directory's immediate child directories that
    /// Git ignores (e.g. `node_modules`, `build`). Used to exclude high-churn
    /// ignored trees from filesystem watching. `.git` is never returned (excluded
    /// separately). Returns `[]` for a bare repo (no working directory).
    ///
    /// Limitation: a directory Git ignores is returned even if it contains a
    /// *tracked* file (force-added, or tracked before the ignore rule). Excluding
    /// such a directory from watching means edits to that tracked file will not
    /// live-refresh the diff. This is an accepted trade-off to avoid recompute
    /// churn on large ignored trees.
    public func ignoredTopLevelDirectories() throws -> [String] {
        guard let workdir = workdirPath else { return [] }
        let fm = FileManager.default
        let workdirURL = URL(fileURLWithPath: workdir)
        let entries = (try? fm.contentsOfDirectory(
            at: workdirURL, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var result: [String] = []
        for url in entries {
            let name = url.lastPathComponent
            guard name != ".git" else { continue }
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            if (try? isPathIgnored(name)) == true {
                result.append(url.path)
            }
        }
        // Sort the (typically handful of) ignored paths rather than every entry: a
        // `URL.lastPathComponent` comparator allocates a String on each comparison.
        // Paths share the same parent directory, so ordering by full path matches
        // ordering by name.
        return result.sorted()
    }

    /// The URL of the named remote, or nil when the remote does not exist or has
    /// no URL configured.
    public func remoteURL(named name: String) throws -> String? {
        var remote: OpaquePointer?
        let code = git_remote_lookup(&remote, pointer, name)
        defer { git_remote_free(remote) }
        if code == GIT_ENOTFOUND.rawValue { return nil }
        try gitCheck(code)
        guard let url = git_remote_url(remote) else { return nil }
        return String(cString: url)
    }

    /// Structured diff of the working tree + index against HEAD (or the whole tree
    /// as additions when HEAD is unborn). Untracked files are included.
    public func diffWorkdirToHead() throws -> GitDiff {
        // Guarded: diffing mmaps live working-directory files (SIGBUS risk). See SigbusGuard.
        try SigbusGuard.run { [self] in
        let tree = try headTree()  // nil when HEAD is unborn
        defer { if let tree { git_tree_free(tree) } }

        var options = git_diff_options()
        try gitCheck(git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION)))
        options.flags =
            GIT_DIFF_INCLUDE_UNTRACKED.rawValue
            | GIT_DIFF_RECURSE_UNTRACKED_DIRS.rawValue
            // Without this flag libgit2 emits zero hunks for any untracked file's
            // content, so the binary-fallback heuristic in `buildFile` would misflag
            // every non-empty untracked text file as binary. With it, untracked text
            // produces real addition hunks while untracked binary still yields none.
            | GIT_DIFF_SHOW_UNTRACKED_CONTENT.rawValue

        // Rename/copy detection is intentionally not enabled: we never call
        // `git_diff_find_similar`, so a renamed file surfaces as a delete + add
        // rather than a single `.renamed` delta. Consequently the `.renamed` /
        // `.copied` arms of `mapStatus` are currently unreachable for this diff.
        var diff: OpaquePointer?
        try gitCheck(git_diff_tree_to_workdir_with_index(&diff, pointer, tree, &options))
        defer { git_diff_free(diff) }

        var files: [GitDiffFile] = []
        let count = git_diff_num_deltas(diff)
        for i in 0..<count {
            var patch: OpaquePointer?
            try gitCheck(git_patch_from_diff(&patch, diff, i))
            defer { git_patch_free(patch) }
            // Read the delta back off the patch (not the diff): binary detection
            // reads file content, which only happens once the patch is generated.
            guard let deltaPtr = git_patch_get_delta(patch) else { continue }
            files.append(try Repository.buildFile(delta: deltaPtr, patch: patch))
        }
        // Present files in a stable alphabetical order by their display path,
        // matching how the diff view lists them. `localizedStandardCompare` gives
        // case-insensitive natural ordering.
        files.sort { lhs, rhs in
            // `GitDiffFile.id` is the display path — reuse it so the sort key can't
            // drift from the identity (see its doc comment for how it is derived).
            lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
        return GitDiff(files: files)
        }
    }

    /// The UTF-8 text of `path` in the HEAD commit's tree, or nil when HEAD is
    /// unborn, the path is absent, the blob is binary, or the bytes aren't UTF-8.
    public func fileTextAtHead(path: String) throws -> String? {
        guard let tree = try headTree() else { return nil }  // HEAD is unborn
        defer { git_tree_free(tree) }

        var entry: OpaquePointer?
        let rc = git_tree_entry_bypath(&entry, tree, path)
        if rc == GIT_ENOTFOUND.rawValue { return nil }
        try gitCheck(rc)
        defer { git_tree_entry_free(entry) }

        var blob: OpaquePointer?
        try gitCheck(git_blob_lookup(&blob, pointer, git_tree_entry_id(entry)))
        defer { git_blob_free(blob) }

        if git_blob_is_binary(blob) == 1 { return nil }
        guard let rawContent = git_blob_rawcontent(blob) else { return nil }
        // `String(bytes:encoding:)` still validates UTF-8 (returning nil on invalid
        // bytes, as documented above), but copies the blob once instead of twice.
        let raw = UnsafeRawBufferPointer(start: rawContent, count: Int(git_blob_rawsize(blob)))
        return String(bytes: raw, encoding: .utf8)
    }

    /// The HEAD commit's tree, or nil when HEAD is unborn / not found.
    private func headTree() throws -> OpaquePointer? {
        var head: OpaquePointer?
        let rc = git_repository_head(&head, pointer)
        if rc == GIT_EUNBORNBRANCH.rawValue || rc == GIT_ENOTFOUND.rawValue { return nil }
        try gitCheck(rc)
        defer { git_reference_free(head) }
        var obj: OpaquePointer?
        try gitCheck(git_reference_peel(&obj, head, GIT_OBJECT_TREE))
        return obj  // a git_tree*; freed by the caller with git_tree_free
    }

    private static func buildFile(
        delta deltaPtr: UnsafePointer<git_diff_delta>, patch: OpaquePointer?
    ) throws -> GitDiffFile {
        let delta = deltaPtr.pointee
        let oldPath = delta.old_file.path.map { String(cString: $0) } ?? ""
        let newPath = delta.new_file.path.map { String(cString: $0) } ?? ""
        let hunkCount = git_patch_num_hunks(patch)

        // Binary detection has two branches:
        //  1. For tracked content (modified/deleted files) libgit2 has blobs on
        //     both sides and runs its content-based check, so `GIT_DIFF_FLAG_BINARY`
        //     is authoritative. We trust it directly.
        //  2. For an added/untracked file libgit2 never sets that flag even when
        //     the content is binary (confirmed empirically: the same bytes staged
        //     into the index, or as a modification to a tracked file, set the flag
        //     correctly). With `GIT_DIFF_SHOW_UNTRACKED_CONTENT` set (see
        //     `diffWorkdirToHead`), untracked *text* now diffs into real hunks, but
        //     patch generation still refuses to emit hunks for *binary* content, so
        //     "no hunks despite a non-empty new side" is the fallback binary signal —
        //     but only for added/untracked files. Applying it to a modified file
        //     would misflag mode-only changes (e.g. `chmod +x`), which legitimately
        //     produce zero hunks with unchanged content.
        let isAdded = delta.status == GIT_DELTA_ADDED || delta.status == GIT_DELTA_UNTRACKED
        let isBinary =
            (delta.flags & GIT_DIFF_FLAG_BINARY.rawValue) != 0
            || (hunkCount == 0 && isAdded && delta.new_file.size > 0)

        var hunks: [GitDiffHunk] = []
        if !isBinary {
            for h in 0..<hunkCount {
                var hunkPtr: UnsafePointer<git_diff_hunk>?
                var lineCount = 0
                try gitCheck(git_patch_get_hunk(&hunkPtr, &lineCount, patch, h))
                guard let hp = hunkPtr else { continue }
                let hunk = hp.pointee
                // Trim the header's newlines on the bytes: building a Foundation
                // `CharacterSet` per hunk just to strip one `\n` off a short ASCII
                // `@@ ... @@` line is pure overhead.
                let header = withUnsafeBytes(of: hunk.header) { raw -> String in
                    let newline = UInt8(ascii: "\n")
                    var start = 0
                    var end = Int(hunk.header_len)
                    while start < end, raw[start] == newline { start += 1 }
                    while end > start, raw[end - 1] == newline { end -= 1 }
                    return String(decoding: raw[start..<end], as: UTF8.self)
                }

                var lines: [GitDiffLine] = []
                for l in 0..<lineCount {
                    var linePtr: UnsafePointer<git_diff_line>?
                    try gitCheck(git_patch_get_line_in_hunk(&linePtr, patch, h, l))
                    if let lp = linePtr, let line = mapLine(lp.pointee) { lines.append(line) }
                }
                hunks.append(GitDiffHunk(
                    header: header,
                    oldStart: Int(hunk.old_start), oldLines: Int(hunk.old_lines),
                    newStart: Int(hunk.new_start), newLines: Int(hunk.new_lines),
                    lines: lines))
            }
        }
        return GitDiffFile(
            oldPath: oldPath, newPath: newPath,
            status: mapStatus(delta.status), isBinary: isBinary, hunks: hunks)
    }

    private static func mapStatus(_ s: git_delta_t) -> GitDiffFile.Status {
        switch s {
        case GIT_DELTA_ADDED, GIT_DELTA_UNTRACKED: return .added
        case GIT_DELTA_DELETED: return .deleted
        case GIT_DELTA_MODIFIED: return .modified
        // `.renamed` / `.copied` are mapped for completeness but are currently
        // unreachable: `diffWorkdirToHead` does not run `git_diff_find_similar`,
        // so libgit2 never emits rename/copy deltas for our diffs.
        case GIT_DELTA_RENAMED: return .renamed
        case GIT_DELTA_COPIED: return .copied
        case GIT_DELTA_TYPECHANGE: return .typechange
        default: return .unmodified
        }
    }

    /// Maps a libgit2 diff line to our value type, or nil for lines that carry no
    /// content of their own. The EOFNL origins mark a "\ No newline at end of file"
    /// note rather than real content, so they are dropped instead of surfaced as
    /// bogus context rows.
    private static func mapLine(_ line: git_diff_line) -> GitDiffLine? {
        let kind: GitDiffLine.Kind
        switch line.origin {
        case CChar(truncatingIfNeeded: GIT_DIFF_LINE_ADDITION.rawValue): kind = .addition
        case CChar(truncatingIfNeeded: GIT_DIFF_LINE_DELETION.rawValue): kind = .deletion
        case CChar(truncatingIfNeeded: GIT_DIFF_LINE_CONTEXT_EOFNL.rawValue),
             CChar(truncatingIfNeeded: GIT_DIFF_LINE_ADD_EOFNL.rawValue),
             CChar(truncatingIfNeeded: GIT_DIFF_LINE_DEL_EOFNL.rawValue):
            return nil
        default: kind = .context
        }
        // Strip the trailing line terminator, handling both LF and CRLF. Only drop a
        // `\r` that immediately precedes the stripped `\n` (CRLF); a lone trailing
        // `\r` is legitimate content (e.g. a CR-terminated final line) and must be
        // preserved. Trimming on the raw bytes rather than the decoded String keeps
        // this to a single copy — every diff line goes through here.
        let content = line.content.map { bytes -> String in
            let raw = UnsafeRawBufferPointer(start: bytes, count: line.content_len)
            var count = raw.count
            if count > 0, raw[count - 1] == UInt8(ascii: "\n") {
                count -= 1
                if count > 0, raw[count - 1] == UInt8(ascii: "\r") { count -= 1 }
            }
            return String(decoding: raw.prefix(count), as: UTF8.self)
        } ?? ""
        return GitDiffLine(
            kind: kind, content: content,
            oldLineNumber: line.old_lineno >= 0 ? Int(line.old_lineno) : nil,
            newLineNumber: line.new_lineno >= 0 ? Int(line.new_lineno) : nil)
    }
}
