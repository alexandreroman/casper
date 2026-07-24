---
name: "Worktree deletion deletes the directory before pruning metadata"
description: "git_worktree_prune orphans the working tree on read-only entries; delete the dir with FileManager first, then prune metadata-only"
type: reference
---

# Worktree deletion deletes the directory before pruning metadata

Casper deletes a workspace's worktree by removing the working-tree
directory with `FileManager` FIRST, then pruning only the libgit2 admin
metadata. The sink is `WorktreeManager.remove(repoPath:name:worktreePath:)`
(`Sources/CasperCore/WorktreeManager.swift`), backed by
`WorktreeManager.forceRemoveDirectory(at:)` and
`Repository.pruneWorktreeMetadata(name:)`
(`Sources/CasperGit/Worktree.swift`, `GIT_WORKTREE_PRUNE_VALID` WITHOUT
`GIT_WORKTREE_PRUNE_WORKING_TREE`).

**Why:** `git_worktree_prune` with `GIT_WORKTREE_PRUNE_WORKING_TREE`
deletes the admin entry (`.git/worktrees/<name>`) BEFORE the working tree,
and its recursive rmdir fails with "Permission denied" (rc -14) on
read-only entries — a directory at mode 0555 (Go module cache, Cargo/npm
caches) whose files can't be unlinked. The admin entry is then already
gone, so a retry finds nothing to prune and the directory is orphaned on
disk forever, while the delete still reports success. The old code also
name-matched via `WorktreeManager.list` and swallowed its error with
`try?`/`?? []`, skipping removal for the healthy target too.

**How to access:** `forceRemoveDirectory` restores owner write+execute on
the root and every directory beneath it (write on regular files, skipping
symlinks so a link target outside the tree is untouched) before
`removeItem`. `setAttributes` is `chmod`, not `lchmod`, so it follows
symlinks: the root is typed via `resourceValues` WITHOUT resolving its
final link — a symlinked root is left untouched (removeItem just unlinks
it), a regular-file root gets 0600, a real directory 0700; descendant
symlinks are likewise skipped, and the enumerator never descends into
them. Both steps are idempotent — a missing directory and an
already-absent admin entry (lookup returns `GIT_ENOTFOUND`) are no-op
successes. Regression tests in
`Tests/CasperCoreTests/WorktreeManagerTests.swift`:
`testRemoveDeletesWorktreeWithReadOnlyEntries`,
`testRemoveDeletesOrphanedWorktreeDirectory`,
`testRemoveDoesNotFollowSymlinkOutOfWorktree` (descendant symlink),
`testForceRemoveDirectoryDoesNotChmodSymlinkRootTarget` (root symlink),
and `testForceRemoveDirectoryOnMissingPathSucceeds` (idempotency).
