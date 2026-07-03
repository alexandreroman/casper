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
        guard let repo else {
            throw GitError(
                code: -1, message: "libgit2 returned success but a null repository")
        }
        return Repository(pointer: repo)
    }

    /// Open the repository at `path` (either a working directory or a `.git`
    /// directory). Does not search parent directories — use `discover` for that.
    public static func open(atPath path: String) throws -> Repository {
        Libgit2.ensureInit()
        var repo: OpaquePointer?
        try gitCheck(git_repository_open(&repo, path))
        guard let repo else {
            throw GitError(
                code: -1, message: "libgit2 returned success but a null repository")
        }
        return Repository(pointer: repo)
    }

    /// Open the repository that owns `path`, searching upward through parents.
    public static func discover(startingAt path: String) throws -> Repository {
        Libgit2.ensureInit()
        var repo: OpaquePointer?
        // flags 0 → search parent directories; no ceiling dirs.
        try gitCheck(git_repository_open_ext(&repo, path, 0, nil))
        guard let repo else {
            throw GitError(
                code: -1, message: "libgit2 returned success but a null repository")
        }
        return Repository(pointer: repo)
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

    /// Short name of the branch HEAD currently points to.
    public func headBranchName() throws -> String {
        var head: OpaquePointer?
        try gitCheck(git_repository_head(&head, pointer))
        defer { git_reference_free(head) }
        var shorthand: UnsafePointer<CChar>?
        shorthand = git_reference_shorthand(head)
        guard let shorthand else {
            throw GitError(code: -1, message: "HEAD has no shorthand name")
        }
        return String(cString: shorthand)
    }

    /// Whether a local branch named `name` exists.
    public func branchExists(_ name: String) throws -> Bool {
        var ref: OpaquePointer?
        let code = git_branch_lookup(&ref, pointer, name, GIT_BRANCH_LOCAL)
        defer { git_reference_free(ref) }
        if code == GIT_ENOTFOUND.rawValue { return false }
        try gitCheck(code)
        return true
    }

    /// Whether local branch `name` is checked out in any working tree. Returns
    /// false if the branch does not exist.
    public func isBranchCheckedOut(_ name: String) throws -> Bool {
        var ref: OpaquePointer?
        let code = git_branch_lookup(&ref, pointer, name, GIT_BRANCH_LOCAL)
        defer { git_reference_free(ref) }
        if code == GIT_ENOTFOUND.rawValue { return false }
        try gitCheck(code)
        let rc = git_branch_is_checked_out(ref)
        if rc < 0 { try gitCheck(rc) }
        return rc == 1
    }

    /// Working-tree status entries (index + worktree), untracked files included.
    public func status() throws -> [FileStatus] {
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

        let count = git_status_list_entrycount(list)
        var result: [FileStatus] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            guard let entry = git_status_byindex(list, index) else { continue }
            let bits = entry.pointee.status
            let delta = entry.pointee.index_to_workdir ?? entry.pointee.head_to_index
            guard let delta else { continue }
            // For a deleted entry `new_file.path` can be NULL; fall back to
            // `old_file.path` so the deletion is not silently dropped.
            let cPath = delta.pointee.new_file.path ?? delta.pointee.old_file.path
            guard let cPath else { continue }
            let path = String(cString: cPath)
            result.append(FileStatus(
                path: path,
                isNew: bits.rawValue & GIT_STATUS_INDEX_NEW.rawValue != 0,
                isModified: bits.rawValue
                    & (GIT_STATUS_INDEX_MODIFIED.rawValue
                       | GIT_STATUS_WT_MODIFIED.rawValue) != 0,
                isDeleted: bits.rawValue
                    & (GIT_STATUS_INDEX_DELETED.rawValue
                       | GIT_STATUS_WT_DELETED.rawValue) != 0,
                isUntracked: bits.rawValue & GIT_STATUS_WT_NEW.rawValue != 0))
        }
        return result
    }

    /// Whether the working tree and index are clean (no changes, no untracked).
    public func isClean() throws -> Bool {
        try status().isEmpty
    }

    /// The URL of the named remote, or nil when the remote does not exist or has
    /// no URL configured.
    public func remoteURL(named name: String) throws -> String? {
        var remote: OpaquePointer?
        guard git_remote_lookup(&remote, pointer, name) == 0 else { return nil }
        defer { git_remote_free(remote) }
        guard let url = git_remote_url(remote) else { return nil }
        return String(cString: url)
    }

    /// Structured diff of the working tree + index against HEAD (or the whole tree
    /// as additions when HEAD is unborn). Untracked files are included.
    public func diffWorkdirToHead() throws -> GitDiff {
        let tree = try headTree()  // nil when HEAD is unborn
        defer { if let tree { git_tree_free(tree) } }

        var options = git_diff_options()
        try gitCheck(git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION)))
        options.flags =
            GIT_DIFF_INCLUDE_UNTRACKED.rawValue | GIT_DIFF_RECURSE_UNTRACKED_DIRS.rawValue

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
        return GitDiff(files: files)
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

        // libgit2 only runs its content-based binary check for sides it already
        // has a blob for; a plain untracked file never gets `GIT_DIFF_FLAG_BINARY`
        // set even when its content is binary (confirmed empirically: the same
        // bytes staged into the index, or as a modification to a tracked file,
        // set the flag correctly). Its patch generation still refuses to emit
        // hunks for such content though, so treat "no hunks despite a non-empty
        // side" as the fallback binary signal.
        let hasContent = delta.old_file.size > 0 || delta.new_file.size > 0
        let isBinary =
            (delta.flags & GIT_DIFF_FLAG_BINARY.rawValue) != 0 || (hunkCount == 0 && hasContent)

        var hunks: [GitDiffHunk] = []
        if !isBinary {
            for h in 0..<hunkCount {
                var hunkPtr: UnsafePointer<git_diff_hunk>?
                var lineCount = 0
                try gitCheck(git_patch_get_hunk(&hunkPtr, &lineCount, patch, h))
                guard let hp = hunkPtr else { continue }
                let hunk = hp.pointee
                let header = withUnsafeBytes(of: hunk.header) { raw -> String in
                    String(decoding: raw.prefix(Int(hunk.header_len)), as: UTF8.self)
                }.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))

                var lines: [GitDiffLine] = []
                for l in 0..<lineCount {
                    var linePtr: UnsafePointer<git_diff_line>?
                    try gitCheck(git_patch_get_line_in_hunk(&linePtr, patch, h, l))
                    if let lp = linePtr { lines.append(mapLine(lp.pointee)) }
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
        case GIT_DELTA_RENAMED: return .renamed
        case GIT_DELTA_COPIED: return .copied
        case GIT_DELTA_TYPECHANGE: return .typechange
        default: return .unmodified
        }
    }

    private static func mapLine(_ line: git_diff_line) -> GitDiffLine {
        let kind: GitDiffLine.Kind
        switch line.origin {
        case CChar(truncatingIfNeeded: GIT_DIFF_LINE_ADDITION.rawValue): kind = .addition
        case CChar(truncatingIfNeeded: GIT_DIFF_LINE_DELETION.rawValue): kind = .deletion
        default: kind = .context
        }
        let content: String
        if let c = line.content {
            content = String(
                decoding: UnsafeRawBufferPointer(start: c, count: line.content_len),
                as: UTF8.self)
        } else {
            content = ""
        }
        let trimmed = content.hasSuffix("\n") ? String(content.dropLast()) : content
        return GitDiffLine(
            kind: kind, content: trimmed,
            oldLineNumber: line.old_lineno >= 0 ? Int(line.old_lineno) : nil,
            newLineNumber: line.new_lineno >= 0 ? Int(line.new_lineno) : nil)
    }
}

/// Per-path working-tree status, reduced to the flags Casper needs.
///
/// The four booleans are not exhaustive: merge-conflicted paths
/// (`GIT_STATUS_CONFLICTED`), type changes, and renames are represented only by
/// the entry being present with all four flags `false`. `status()`/`isClean()`
/// still report such a tree as dirty; consumers must not assume these flags
/// cover every change kind.
public struct FileStatus: Equatable, Sendable {
    public let path: String
    public let isNew: Bool
    public let isModified: Bool
    public let isDeleted: Bool
    public let isUntracked: Bool

    public init(
        path: String, isNew: Bool, isModified: Bool,
        isDeleted: Bool, isUntracked: Bool
    ) {
        self.path = path
        self.isNew = isNew
        self.isModified = isModified
        self.isDeleted = isDeleted
        self.isUntracked = isUntracked
    }
}
