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
  checked-out), worktree add/list/lookup/validate/prune, status/isClean.
  `WorktreeInfo`, `GitError`.
- **Worktree model** — creating a workspace = `git_worktree_add` on a chosen
  branch/base, then opening a plain Ghostty terminal in its folder. Dirty/locked
  states are surfaced as clear UI errors, never a crash (`git_status`,
  `git_worktree_validate`).
- **Diff (planned)** — structured hunks/line-stats via `git_diff` (working tree
  vs base/HEAD, and branch-vs-merge-base line counts). No text parsing. Feeds the
  diff viewer (`app-ui.md`) and the workspace diff summary (`space-project.md`).

Interop gotchas (variadic `_v` functions, pointer lifecycle, error codes) are
captured in the [[libgit2-swift-interop]] project-memory note.

## Remaining

- **`git_diff` is not implemented** — the single prerequisite blocking both the
  diff viewer and the workspace diff summary.
- Standing limitations: `remove` prunes the worktree but not its branch (an opaque
  `.gitFailure` on same-name recreation); libgit2 unpinned in brew/CI;
  `WorktreeManager` uses `Repository.open` (exact root) not `discover`.
