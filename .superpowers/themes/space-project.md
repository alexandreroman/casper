# Theme: Space (Project) & Workspace Diff Summary

**Status:** ❌ not started — design + plan only, no `Space` type (see
`../status.md`) · **Plan:** `../plans/space-project.md` (actionable) ·
**Extends** `../architecture.md` (data model, sidebar, worktrees, persistence).

Promotes the sidebar's implicit "group by repository" into a first-class
**Space**, and enriches each workspace row with a Git diff summary. Depends on
CasperGit `git_diff` (`git-worktrees.md`) and the CasperUI sidebar (`app-ui.md`).

## Design

### Space — the project level

A **Space** is a **Git repository**, sitting between `Session` and `Workspace`.
It maps 1:1 to a `repoPath` and always has **≥ 1 workspace**: exactly one
**primary** (the repo's main working tree, typically `main`) and 0..n **linked**
(each a `git worktree add`). *Invariant: Space = Git repository, always ≥ 1
workspace.*

- **Naming** — default from the `origin` remote's last path segment without `.git`
  (fallback: the root folder name). Renamable; a renamed Space stops tracking the
  folder/remote.
- **Lifecycle** — open a folder (offer `git init` with explicit auth if not a
  repo); add a workspace via `git worktree add`; **remove is non-destructive**
  (drops the Space from `session.json` and releases ports; leaves the repo,
  worktrees, and branches on disk).

### Data model changes (vs `architecture.md`)

- `repoPath` **moves up** from `Workspace` to `Space` (one repo per Space).
- `Workspace` gains `kind: primary | linked`, `baseBranch`, and a derived
  `diffStat` (not persisted). `LayoutNode`/`Surface`/`Todo`/`AgentState` unchanged.

### Sidebar

Each Space is a **collapsible group header** (repo name + chevron), **no state
aggregation** — agent state stays on the workspace rows; the primary is listed
first.

### Workspace diff summary

- Counts the **branch's divergence from its base**: the diff between the workspace
  branch and the **merge-base** of that branch and `baseBranch` (commits
  included), so it stays stable after the agent commits.
- Display: `+<insertions>` green / `−<deletions>` red — **line counts only**,
  **hidden entirely when empty** (the primary on `main` typically shows nothing).
- Source: libgit2 `git_diff` via CasperGit; `diffStat` is **derived**, recomputed
  on open/change (refresh trigger — FSEvents / hooks / periodic — is a plan
  detail).

## Unchanged from the base design

Ports remain **per workspace** (`CASPER_PORT`), not per Space. Hooks stay global.
No `CASPER_PROJECT` env in v1. `SessionStore` serializes the full
`Session → Space → Workspace` tree.

## Implementation

Not started. The full task-by-task plan is retained at
`../plans/space-project.md` (model refactor + `session.json` migration + CasperGit
remote URL / divergence stats + repo-name derivation + Space assembly + diff
helper).
