---
name: "FSEvents DirectoryWatcher gotchas"
description: "Why CasperCore's DirectoryWatcher omits IgnoreSelf, canonicalizes paths, and barriers stop() only for off-queue callers"
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
  symlinks). Both the watch root and each exclusion path are resolved before
  use; a non-canonical exclusion also fails to match and lets `.git` churn wake
  the watcher.
- **`stop()` barriers off-queue callers and recognizes its own queue.** The C
  callback runs on a serial queue with an *unretained* context, so `stop()` ends
  with a `queue.sync {}` barrier that drains any in-flight or queued callback
  before teardown returns, closing the use-after-free window. Off-queue callers
  — the main actor, through the owner's reconfigure path — get that full
  barrier, and the owner's `onChange` hop is a non-blocking
  `DispatchQueue.main.async`, so it never blocks the queue against it. Same
  discipline as [[swift6-network-concurrency]]. A caller already *on* the
  callback queue would self-deadlock on that barrier, and `deinit` calls
  `stop()` unconditionally, so releasing the watcher's last reference from
  inside the callback lands `stop()` there: "never call `stop()` from the
  callback queue" is not an invariant the type can enforce. The queue therefore
  carries a per-instance `DispatchSpecificKey` set at init, and `stop()` reads
  `DispatchQueue.getSpecific` to tear down inline when it is already on that
  queue — the running callback is the only in-flight one, so the barrier's
  guarantee holds with nothing left to drain.
  `DirectoryWatcherTests.testStopFromTheCallbackQueueDoesNotDeadlock` pins the
  reentrant case.

**Why:** these are silent-failure modes — the watcher compiles and "runs" but
delivers nothing (IgnoreSelf, symlink) or crashes rarely under teardown races.

**How to access:** see `Sources/CasperCore/DirectoryWatcher.swift`. Gitignored
exclusions come from libgit2 via `Repository.ignoredTopLevelDirectories()`
(`git_ignore_path_is_ignored`), never by parsing `.gitignore` text.
