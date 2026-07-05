---
name: "Diff refresh uses two FSEvents watchers"
description: "Why AppModel arms a worktree watcher (excl. .git) AND a reflog watcher on <gitdir>/logs to refresh the diff after a commit"
type: reference
---

# Diff refresh uses two FSEvents watchers

`AppModel.armWorktreeWatcher()` arms **two** independent FSEvents watchers for the
selected workspace, and both funnel through the same `diffDebouncer` →
`handleSelectedWorktreeChange()` → `diffRevision += 1`, which is the *only* trigger
that invalidates the memoized diff (cache key `(workspaceID, diffRevision)`):

- **`worktreeWatcher`** — watches the worktree root, **excluding `.git`** (and
  gitignored top-level dirs). The `.git` exclusion is load-bearing: it stops git's
  high-frequency internal writes (index, lockfiles on every status/add) from waking
  the watcher. See [[fsevents-directory-watcher]].
- **`gitMetaWatcher`** — watches `<gitDirPath>logs` (the resolved gitdir's reflog
  dir; `Repository.gitDirPath` carries a trailing slash and, for a linked worktree,
  resolves to `<maindir>/.git/worktrees/<name>/`). No exclusions.

**Why the second watcher exists:** a `git commit` writes *only* inside `.git`
(index, HEAD, refs, logs) and leaves every working-tree file byte-for-byte
identical. With just the `.git`-excluded worktree watcher, a commit fired no event,
`diffRevision` never bumped, and the diff stayed stale (still showing the just-
committed files). `logs/HEAD` is appended on every HEAD-moving op (commit, checkout,
reset, merge, rebase) but is **never** written by `git status`/`add`/`diff`, so
watching `<gitdir>/logs` catches commits with zero event-storm risk. Verified
end-to-end: committing a file live clears it from the diff and drops the badge count.

**How to apply:** keep both watchers. Do not "simplify" by dropping `gitMetaWatcher`
(reintroduces the stale-diff-after-commit bug) or by un-excluding `.git` on the
worktree watcher (reintroduces status/add event storms). Tear both down symmetrically
(they are stopped/niled together in `deinit` and at the top of `armWorktreeWatcher`).
Both go through the injectable `makeWorktreeWatcher` seam so tests can stub them.
