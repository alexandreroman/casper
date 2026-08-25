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
- **Repository identity** — `isBare`, `commonDirPath` (the `.git` directory
  every working tree of a repository shares, and so the repository's identity)
  and `isLinkedWorktree`, plus **`mainWorkingTree()`**, which opens that common
  directory to reach the main repository and returns its workdir. That is what
  lets a linked worktree opened on its own pull its repository in rather than
  standing alone — including the two refusals, a bare repository and a
  main working tree that does not resolve to a folder of the same repository
  (see `space-project.md`).
- **`fileTextAtHead(path:)`** — the HEAD side of a file, read by the diff
  service.
- **Worktree model** — creating a workspace = `git_worktree_add` on a chosen
  branch/base, then opening a plain Ghostty terminal in its folder. Cleanliness
  is read through `git_status_list_new` (`isClean`), and a failure at any step
  is surfaced as a clear UI error, never a crash. There is no
  `git_worktree_validate` wrapper: libgit2 reports the failure directly from the
  operation being attempted, so a second validating call would only duplicate
  it.
- **Diff — ✅ built for working-tree-vs-HEAD.** `Repository.diffWorkdirToHead()`
  returns a structured `GitDiff` (files → hunks → lines, statuses, binary flag,
  `insertions`/`deletions`) — no text parsing — feeding the diff viewer
  (`app-ui.md`). The types live in `Sources/CasperGit/Diff.swift`.
  (Branch-vs-merge-base line counts were designed for the workspace diff
  summary, now **dropped** — see `space-project.md`.)

- **Merge — ✅ built.** `Repository.mergeBranchHeadless(…)` performs the
  worktree-free merge behind "Merge and Close Workspace…", returning a
  `MergeOutcome` and surfacing `MergeConflictError` /
  `MergeUnrelatedHistoriesError`; `forceCheckoutHead()` is its recovery path.
  See `Sources/CasperGit/Merge.swift`.

Interop gotchas (variadic `_v` functions, pointer lifecycle, error codes) are
captured in the [[libgit2-swift-interop]] project-memory note.

## Standing limitations

- `WorktreeManager.remove` prunes a worktree without deleting its branch. Its
  one production caller deletes the branch on the next line, so recreating a
  same-named workspace works; a second caller that forgets would meet an opaque
  `.gitFailure`.
- **libgit2 is unpinned** in Homebrew and in CI, so a brew bump can change diff
  or status behaviour underfoot.
