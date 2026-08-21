# Theme: Space (Project)

**Status:** ◐ **Space model built by CasperUI UI-2** (`Session → Space →
Workspace`; `repoPath` up on `Space.folderPath`; `Workspace.kind`/`baseBranch`);
only **Space rename remains** (see `../status.md` and `app-ui.md`) · **Extends**
`../architecture.md` (data model, sidebar, worktrees, persistence).

> **The per-workspace `+/−` diff summary is dropped** (decision, 2026-07-06) —
> it is no longer planned. The branch-vs-merge-base divergence badge on each
> workspace row will not be built; the title-bar working-tree-vs-HEAD summary
> already covers the practical need. The design text below is retained for the
> record but is **not** a work item.

Promotes the sidebar's implicit "group by repository" into a first-class
**Space**. The Space grouping shipped with the CasperUI sidebar in UI-2
(`app-ui.md`).

> **UI-2 relaxes the invariant below.** UI-2 defines a Space as a **folder that
> may or may not be a Git repo**: a non-Git folder is a *degenerate* Space with
> exactly one primary workspace and no worktree creation (the UI-1 behaviour is
> preserved), and it is promoted to a full Git Space once its folder gains a
> `.git` — detected live by the selected workspace's filesystem watcher (and
> once per Space at launch), not by a heartbeat poll; it is demoted back to
> degenerate if the `.git` is later removed. The "always a Git repository"
> wording in the next section is the original design intent, superseded on this
> point by UI-2.

## Design

### Space — the project level

A **Space** is a **Git repository**, sitting between `Session` and `Workspace`.
It maps 1:1 to a `repoPath` and always has **≥ 1 workspace**: exactly one
**primary** (the repo's main working tree, typically `main`) and 0..n **linked**
(each a `git worktree add`). *Invariant: Space = Git repository, always ≥ 1
workspace.*

- **Naming** — default from the `origin` remote's last path segment without
  `.git` (fallback: the root folder name). Renamable; a renamed Space stops
  tracking the folder/remote.
- **Lifecycle** — open a folder (offer `git init` with explicit auth if not a
  repo); add a workspace via `git worktree add`; **remove is non-destructive**
  (drops the Space from `session.json` and releases ports; leaves the repo,
  worktrees, and branches on disk).

### Data model changes (vs `architecture.md`)

- `repoPath` **moves up** from `Workspace` to `Space` (one repo per Space).
- `Workspace` gains `kind: primary | linked` and `baseBranch`.
  `LayoutNode`/`Surface`/`Todo`/`AgentState` unchanged. (A derived `diffStat`
  was designed for the dropped diff summary; it was never built.)

### Sidebar

Each Space is a **collapsible group header** (repo name + chevron), **no state
aggregation** — agent state stays on the workspace rows; the primary is listed
first.

### Workspace diff summary — dropped

*Design retained for the record; not a work item (see the note at the top).* The
original intent was a per-row **branch-vs-merge-base** divergence badge
(`+<insertions>` green / `−<deletions>` red, line counts only, hidden when
empty). It is superseded by the title-bar working-tree-vs-HEAD summary, which
already ships.

## Unchanged from the base design

Ports remain **per workspace** (`CASPER_PORT`, injected in `linked` workspaces
only), not per Space. No `CASPER_PROJECT` env in v1. `SessionStore` serializes
the full `Session → Space → Workspace` tree.

## Implementation

**Partly built by CasperUI UI-2.** Done: the model refactor (`repoPath` up to
`Space.folderPath`, `Workspace.kind`/`baseBranch`, `Session.spaces`), Space
assembly, the collapsible Space-grouped sidebar, `CasperGit`
`Repository.remoteURL`, and repo-name derivation from `origin`. Persistence uses
a clean break (the existing `SessionStore` self-heal discards incompatible
legacy files), not the migration the original plan described.

Remaining for this theme: **Space rename** only. The per-workspace `+/−` diff
summary is **dropped** (see the top note), so the divergence-stats and
diff-helper tasks in the old plan (`../plans/space-project.md`) are moot — that
plan is superseded (its model/remote/naming tasks already landed with UI-2).
