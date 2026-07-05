# Theme: Git & Worktrees (CasperGit)

**Modules:** CasperGit + Clibgit2 · **Status:** ◐ partial (see `../status.md`) ·
**Code:** `Sources/CasperGit/`, `Sources/Clibgit2/`

A thin in-house Swift wrapper over the **libgit2** C API — no external `git`
binary. We own this surface; it exposes only what Casper needs.

## Design

- **`Clibgit2`** — a `.systemLibrary` binding libgit2 via Homebrew + pkg-config
  (dynamic link; static vendoring deferred to packaging). Build host needs
  `brew install libgit2 pkgconf`.
- **`Repository`** — open/discover/init, branch queries (head, existence,
  checked-out), worktree add/list/lookup/validate/prune, status/isClean, and Git
  ignore checks (`isPathIgnored`, `ignoredTopLevelDirectories` over
  `git_ignore_path_is_ignored` — used to keep high-churn ignored dirs out of the
  filesystem watcher, `app-ui.md`). `WorktreeInfo`, `GitError`.
- **Worktree model** — creating a workspace = `git_worktree_add` on a chosen
  branch/base, then opening a plain Ghostty terminal in its folder. Dirty/locked
  states are surfaced as clear UI errors, never a crash (`git_status`,
  `git_worktree_validate`).
- **Diff — ◐ built for working-tree-vs-HEAD.** `Repository.diffWorkdirToHead()`
  returns a structured `GitDiff` (files → hunks → lines, statuses, binary flag) —
  no text parsing — feeding the diff viewer (`app-ui.md`). The branch-vs-merge-base
  line counts for the workspace diff summary (`space-project.md`) remain.

Interop gotchas (variadic `_v` functions, pointer lifecycle, error codes) are
captured in the [[libgit2-swift-interop]] project-memory note.

## Remaining

- **`git_diff` — ✅ built** (`diffWorkdirToHead()`, working tree + index vs HEAD).
  The branch-vs-merge-base line counts for the workspace diff summary remain.
- Standing limitations: `remove` prunes the worktree but not its branch (an opaque
  `.gitFailure` on same-name recreation); libgit2 unpinned in brew/CI;
  `WorktreeManager` uses `Repository.open` (exact root) not `discover`.
