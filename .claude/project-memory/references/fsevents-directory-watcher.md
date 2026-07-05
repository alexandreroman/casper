---
name: "FSEvents DirectoryWatcher gotchas"
description: "Why CasperCore's DirectoryWatcher omits IgnoreSelf, canonicalizes paths, and barriers stop()"
type: reference
---

# FSEvents DirectoryWatcher gotchas

`CasperCore/DirectoryWatcher` wraps FSEvents to watch a worktree subtree. Three
non-obvious constraints, each verified the hard way:

- **Never set `kFSEventStreamCreateFlagIgnoreSelf`.** It suppresses events
  triggered by the current process, which silently drops Casper's own in-process
  libgit2 writes (e.g. a degenerate→Git promotion's git work) and same-process
  test writes. Flags stay `NoDefer | WatchRoot`. Do not re-add IgnoreSelf as an
  "optimization".
- **Canonicalize every path with `realpath(3)`.** FSEvents delivers *no* events
  when the watch root traverses a symlink (`/var`→`/private/var`, `/tmp`, user
  symlinks). Both the watch root and each exclusion path are resolved before use;
  a non-canonical exclusion also fails to match and lets `.git` churn wake the
  watcher.
- **`stop()` ends with a `queue.sync {}` barrier.** The C callback runs on a
  serial queue with an *unretained* context while `stop()` runs on the main actor;
  the barrier drains any in-flight callback before teardown to avoid a
  use-after-free. Same discipline as [[swift6-network-concurrency]]. `stop()` must
  never be called from the callback queue (it isn't); the `onChange` hop uses a
  non-blocking `DispatchQueue.main.async`, so the barrier can't deadlock.

**Why:** these are silent-failure modes — the watcher compiles and "runs" but
delivers nothing (IgnoreSelf, symlink) or crashes rarely under teardown races.

**How to access:** see `Sources/CasperCore/DirectoryWatcher.swift`. Gitignored
exclusions come from libgit2 via `Repository.ignoredTopLevelDirectories()`
(`git_ignore_path_is_ignored`), never by parsing `.gitignore` text.
