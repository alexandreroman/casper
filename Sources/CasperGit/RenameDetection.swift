import Clibgit2
import Foundation
import os

/// CasperGit sits below CasperCore, so it cannot reach `CasperLog`; it logs under the
/// same subsystem, which is what the `debug-casper` skill filters on.
private let log = Logger(subsystem: "com.github.alexandreroman.casper", category: "git")

extension Repository {
    /// The rename budget, in git's `diff.renameLimit` terms and at git's default for
    /// `git diff` and `git status`: detection is skipped outright when deleted files ×
    /// added files exceeds its square — one million similarity comparisons.
    ///
    /// libgit2 has no such global bound (its own `rename_limit` caps the sources tried
    /// per target), and this pass re-runs on every worktree change. Measured on an
    /// Apple-silicon Mac, a thousand deleted 2 KB files against a thousand untracked
    /// ones — the full million — add about a third of a second to a diff that
    /// otherwise takes a fifth, off the main thread. Slow, but a change that size is rare,
    /// and it is what `git status` still pairs up; a tighter budget would show a
    /// rename git reports as a deletion and an addition.
    static let renameLimit = 1000

    /// Whether pairing `sources` deleted files with `targets` added ones fits the
    /// `renameLimit` budget. With nothing on one side there is nothing to pair.
    static func isRenameDetectionAffordable(sources: Int, targets: Int) -> Bool {
        guard sources > 0, targets > 0 else { return false }
        return sources * targets <= renameLimit * renameLimit
    }

    /// Pair each deleted file in `diff` with a similar added one into a single
    /// `GIT_DELTA_RENAMED` delta, as `git status` does.
    ///
    /// Best-effort: rename detection only refines the diff, so a failure — an
    /// untracked target that vanishes or turns unreadable mid-pass — is logged and
    /// leaves the deltas as they were, deletions and additions, rather than failing
    /// the whole diff. libgit2 compares every pair before rewriting any delta, so a
    /// failed pass leaves no half-applied renames behind.
    static func detectRenames(in diff: OpaquePointer) {
        let (sources, targets) = renameCandidateCounts(in: diff)
        guard isRenameDetectionAffordable(sources: sources, targets: targets) else { return }

        var metric = sizeCappedSimilarityMetric()
        var options = git_diff_find_options()
        do {
            try gitCheck(git_diff_find_options_init(&options, UInt32(GIT_DIFF_FIND_OPTIONS_VERSION)))
            // Every knob is set explicitly, since a zero means "whatever the user's
            // config says" (`diff.renames`, `diff.renameLimit`), and the view must not
            // depend on it. `FOR_UNTRACKED` lets untracked files take part: a plain `mv`
            // with the index untouched yields a deleted old path plus an *untracked* new
            // one, and this view presents untracked files as additions. Copy detection
            // stays off, as it is by default in `git status` and `git diff`.
            options.flags = GIT_DIFF_FIND_RENAMES.rawValue | GIT_DIFF_FIND_FOR_UNTRACKED.rawValue
            options.rename_limit = renameLimit
            try withUnsafeMutablePointer(to: &metric) { metricPointer in
                options.metric = metricPointer
                try gitCheck(git_diff_find_similar(diff, &options))
            }
        } catch {
            log.error("rename detection skipped: \(String(describing: error), privacy: .public)")
        }
    }

    /// How many deltas libgit2 will weigh as rename sources (deletions) and targets
    /// (additions, untracked files included) under the flags `detectRenames` sets.
    private static func renameCandidateCounts(in diff: OpaquePointer) -> (sources: Int, targets: Int) {
        var sources = 0
        var targets = 0
        for i in 0..<git_diff_num_deltas(diff) {
            guard let delta = git_diff_get_delta(diff, i) else { continue }
            switch delta.pointee.status {
            case GIT_DELTA_DELETED: sources += 1
            case GIT_DELTA_ADDED, GIT_DELTA_UNTRACKED: targets += 1
            default: break
            }
        }
        return (sources, targets)
    }

    /// The options libgit2's own default metric hashes with (`normalize_find_opts` in
    /// its `diff_tform.c`, when no whitespace flag is given).
    private static let hashsigOptions = git_hashsig_option_t(
        rawValue: GIT_HASHSIG_SMART_WHITESPACE.rawValue | GIT_HASHSIG_ALLOW_SMALL_FILES.rawValue)

    /// libgit2's default similarity metric, rebuilt on the public `git2/sys/hashsig.h`
    /// API, except that a file over `maxDiffFileSize` gets no signature — which
    /// libgit2 reads as "not comparable" and skips.
    ///
    /// The default hashes a working-tree file straight off disk with no size cap
    /// (`git_diff_options.max_size` bounds only patch generation), so once any tracked
    /// file is deleted, every untracked file of a compatible size — any size at all
    /// next to a source of 127 bytes or less — would be read in full on each refresh.
    /// The closures are `@convention(c)` callbacks, so they capture nothing and read
    /// the cap and options off statics rather than the `payload`.
    private static func sizeCappedSimilarityMetric() -> git_diff_similarity_metric {
        git_diff_similarity_metric(
            file_signature: { out, _, path, _ in
                guard let out, let path else { return 0 }
                var info = stat()
                if stat(path, &info) == 0, info.st_size > Repository.maxDiffFileSize { return 0 }
                var signature: OpaquePointer?
                let code = git_hashsig_create_fromfile(&signature, path, Repository.hashsigOptions)
                if code == 0 { out.pointee = UnsafeMutableRawPointer(signature) }
                return code
            },
            buffer_signature: { out, _, buffer, length, _ in
                // A blob out of the object database. It is already loaded by the time
                // libgit2 asks, but the cap still spares hashing it and keeps a file
                // over the cap out of the pairing whichever side it sits on.
                guard let out, let buffer, Int64(length) <= Repository.maxDiffFileSize else { return 0 }
                var signature: OpaquePointer?
                let code = git_hashsig_create(&signature, buffer, length, Repository.hashsigOptions)
                if code == 0 { out.pointee = UnsafeMutableRawPointer(signature) }
                return code
            },
            free_signature: { signature, _ in
                git_hashsig_free(OpaquePointer(signature))
            },
            similarity: { score, first, second, _ in
                let result = git_hashsig_compare(OpaquePointer(first), OpaquePointer(second))
                guard result >= 0 else { return result }
                score?.pointee = result
                return 0
            },
            payload: nil)
    }
}
