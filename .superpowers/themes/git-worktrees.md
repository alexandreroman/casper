# Theme: Git & Worktrees (CasperGit)

**Modules:** CasperGit + Clibgit2 + CSigbusGuard · **Status:** ✅ built (see
`../status.md`) · **Code:** `Sources/CasperGit/`, `Sources/Clibgit2/`,
`Sources/CSigbusGuard/`

A thin in-house Swift wrapper over the **libgit2** C API — no external `git`
binary. We own this surface; it exposes only what Casper needs.

## Design

- **`Clibgit2`** — a `.systemLibrary` binding libgit2 via Homebrew + pkg-config
  (dynamic link; static vendoring deferred to packaging). Build host needs
  `brew install libgit2 pkgconf`.
- **`CSigbusGuard`** — a small C target wrapping a diff call in a `SIGBUS`
  guard. libgit2 mmaps blobs, so a file **truncated while the diff is running**
  faults the whole process; the guard `siglongjmp`s out of the faulting thread
  back into `CasperGit`, which turns it into a thrown error the UI can report.
  The jump buffer is `_Thread_local` because concurrent diffs run on several
  cooperative-pool threads and the handler executes on the faulting one. A
  `SIGBUS` raised *outside* a guarded region restores the default disposition
  and re-executes the instruction, so a genuine crash still produces a genuine
  crash report. See [[sigbus-guard-diff]].
- **`Repository`** — `initialize`/`open` (an **exact** root path; there is
  deliberately no `git_repository_discover` wrapper, so a path that is not
  itself a repository root is an error rather than a silent walk up the tree),
  branch queries (head, existence, checked-out), worktree add/list/lookup/prune,
  status/isClean, and Git ignore checks (`isPathIgnored`,
  `ignoredTopLevelDirectories` over `git_ignore_path_is_ignored` — used to keep
  high-churn ignored dirs out of the filesystem watcher, `app-ui.md`).
  `WorktreeInfo`, `GitError`.
- **Worktree model** — creating a workspace = `git_worktree_add` on a chosen
  branch/base, then opening a plain Ghostty terminal in its folder. Cleanliness
  is read through `git_status_list_new` (`isClean`), and a failure at any step
  is surfaced as a clear UI error, never a crash. There is no
  `git_worktree_validate` wrapper: libgit2 reports the failure directly from the
  operation being attempted, so a second validating call would only duplicate
  it.
- **Diff — ✅ built for working-tree-vs-HEAD.** `Repository.diffWorkdirToHead()`
  returns a structured `GitDiff` (files → hunks → lines, statuses, binary flag)
  — no text parsing — feeding the diff viewer (`app-ui.md`).
  (Branch-vs-merge-base line counts were designed for the workspace diff
  summary, now **dropped** — see `space-project.md`.)

- **Merge — ✅ built.** `Repository.mergeBranchHeadless(…)` performs the
  worktree-free merge behind "Merge and Close Workspace…", returning a
  `MergeOutcome` and surfacing `MergeConflictError` /
  `MergeUnrelatedHistoriesError`; `forceCheckoutHead()` is its recovery path.
  See `Sources/CasperGit/Merge.swift`.

Interop gotchas (variadic `_v` functions, pointer lifecycle, error codes) are
captured in the [[libgit2-swift-interop]] project-memory note.

## Remaining

- **`git_diff` — ✅ built** (`diffWorkdirToHead()`, working tree + index vs
  HEAD). (Branch-vs-merge-base line counts for the workspace diff summary are
  **dropped** — see `space-project.md`.)
- Standing limitations: `remove` prunes the worktree but not its branch (an
  opaque `.gitFailure` on same-name recreation); libgit2 is unpinned in
  brew/CI.
