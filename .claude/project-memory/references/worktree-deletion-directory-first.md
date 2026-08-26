---
name: "Worktree deletion deletes the directory before pruning metadata"
description: "git_worktree_prune orphans the working tree on read-only entries; delete the dir with FileManager first, then prune metadata-only"
type: reference
---

# Worktree deletion deletes the directory before pruning metadata

`WorktreeManager.remove(repoPath:name:worktreePath:)` and
`WorktreeManager.forceRemoveDirectory(at:)` carry the ordering rule and the
`git_worktree_prune` trap it sidesteps, along with the symlink and idempotency
handling.

**The second trap, which the code cannot show:** resolving the worktree to
delete by name-matching through `WorktreeManager.list`, and swallowing that
call's error with `try?` / `?? []`, skips removal for a perfectly healthy target
— the empty list simply finds no match and the delete reports success. A failed
listing has to propagate, never degrade to "nothing to delete".

**How to access:** the regression tests are in
`Tests/CasperCoreTests/WorktreeManagerTests.swift` —
`testRemoveDeletesWorktreeWithReadOnlyEntries`,
`testRemoveDeletesOrphanedWorktreeDirectory`,
`testRemoveDoesNotFollowSymlinkOutOfWorktree` (descendant symlink),
`testForceRemoveDirectoryDoesNotChmodSymlinkRootTarget` (root symlink), and
`testForceRemoveDirectoryOnMissingPathSucceeds` (idempotency).
