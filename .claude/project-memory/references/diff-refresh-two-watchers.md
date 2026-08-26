---
name: "Diff refresh uses two FSEvents watchers"
description: "Why AppModel arms a worktree watcher (excl. .git) AND a reflog watcher on <gitdir>/logs to refresh the diff after a commit"
type: reference
---

# Diff refresh uses two FSEvents watchers

`AppModel.armWorktreeWatcher` arms two independent FSEvents watchers per
selected workspace — the worktree root with `.git` excluded, and the resolved
gitdir's reflog directory — both funnelling through the same debounced hop.

**Why the second watcher exists:** a `git commit` writes *only* inside `.git`
(index, HEAD, refs, logs) and leaves every working-tree file byte-for-byte
identical. A `.git`-excluded worktree watcher therefore sees nothing at all when
a commit lands, so `diffRevision` never bumps and the diff keeps showing the
files that were just committed. `logs/HEAD` is appended on every HEAD-moving op
(commit, checkout, reset, merge, rebase) but is **never** written by
`git status`/`add`/`diff`, so watching `<gitdir>/logs` catches commits with zero
event-storm risk. Verified end-to-end: committing a file live clears it from the
diff and drops the badge count.

**Why the `.git` exclusion on the first watcher:** git's internal writes (index,
lockfiles on every status/add) are high-frequency enough to keep the watcher
awake continuously. See [[fsevents-directory-watcher]].

**How to apply:** both watchers are load-bearing, and each guards a distinct
failure. Dropping `gitMetaWatcher` leaves the diff stale after a commit;
un-excluding `.git` on the worktree watcher opens the status/add event storm.
Tear them down symmetrically — they are stopped and niled together — and route
both through the injectable `makeWorktreeWatcher` seam so tests can stub them.
