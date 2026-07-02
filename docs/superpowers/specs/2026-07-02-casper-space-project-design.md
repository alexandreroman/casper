# Casper — Space (Project) & Workspace Diff Summary — Design Specification

**Date:** 2026-07-02
**Status:** Approved design, pending implementation plan
**Author:** Alexandre Roman (with Claude)
**Extends:** [2026-07-01-casper-design.md](2026-07-01-casper-design.md) (§5 Data Model,
§6 Sidebar, §8 Worktree Management, §10 Persistence)

## 1. Purpose

The base design nests `Session → [Workspace]`, with the sidebar grouping workspace
rows *implicitly* by repository (§6). This spec makes that grouping an explicit
first-class concept — the **Space** (a.k.a. project) — and enriches each workspace
row with a **Git diff summary** (added/removed lines). Nothing else in the base
design changes; ports, hooks, and the layout model are untouched.

## 2. Space — the project level

A **Space** is a **Git repository**. It sits between `Session` and `Workspace`:

- A Space maps 1:1 to a Git repository (`repoPath`).
- A Space **always has ≥ 1 workspace**: exactly one **primary** workspace (the
  repository's main working tree, typically on `main`) and **0..n linked**
  workspaces (each a `git worktree add` on another branch).
- The sidebar's implicit "group by repository" (base §6) **becomes** the Space:
  each Space is a group.

**Invariant:** *Space = Git repository, always ≥ 1 workspace (the primary).*
Opening a non-Git folder is not a Space until initialized — see §5.

### 2.1 Naming

- **Default name** derives from the repository:
  - From the `origin` remote URL, take the last path segment without `.git` —
    e.g. `github.com/alexandreroman/my-app.git` → `my-app`.
  - **Fallback** (no remote, e.g. a fresh `git init`): the root **folder name**.
- The user may **rename** a Space. After a rename the name is fixed and **does not
  follow** the folder or remote anymore.

## 3. Data model

```
Session
 └─ [Space]
     ├─ id, name                 // default = repo name (see §2.1), renamable
     ├─ repoPath                 // moved up from Workspace: one repo per Space
     └─ [Workspace]
         ├─ id, name
         ├─ kind: primary | linked
         ├─ worktreePath, branch
         ├─ baseBranch           // reference branch for the divergence diff, e.g. main (§6)
         ├─ agentState: idle | running | waiting | done | error | unknown
         ├─ todos: [Todo]
         ├─ pendingNotification: Bool
         ├─ diffStat: { insertions, deletions }   // DERIVED, not persisted (§6)
         ├─ portBase: Int        // 10-port block, per workspace (unchanged)
         └─ layout: LayoutNode
```

Changes vs base §5:

- `repoPath` **moves up** from `Workspace` to `Space` (one repository per Space; no
  duplication).
- `Workspace` gains `kind` (`primary | linked`): the **primary** points at the
  repository's main working tree; **linked** workspaces are added worktrees.
- `Workspace` gains `baseBranch` and the derived `diffStat` (§6).

`LayoutNode`, `Surface`, `Todo`, and the `AgentState` set are **unchanged** from the
base design.

## 4. Sidebar

- Each **Space** renders as a **collapsible group header** — repository name +
  chevron. **No state aggregation**: the header shows no rolled-up badge or count;
  agent state stays entirely on the workspace rows. (A collapsed group therefore
  hides its workspaces' activity — accepted trade-off, chosen for simplicity.)
- The **primary** workspace is listed first within its Space (typically `main`).
- Each **workspace row** shows (base §6, plus the diff summary from §6 below):
  - state badge — running ● / waiting ◐ / done ✓ / error ✕ / idle ○ / unknown
  - name
  - Git branch / worktree label
  - todo progress — `completed / total` plus the current `in_progress` label
  - **diff summary** — `+<insertions>` in green / `−<deletions>` in red, **hidden
    when the diff is empty** (§6)
  - pending-notification dot

## 5. Space lifecycle

- **Open a Space** — the user picks a folder:
  - If it is a Git repository → it becomes the Space; Casper creates the **primary**
    workspace on the repository's main working tree.
  - If it is **not** a Git repository → Casper offers to run `git init` (explicit
    user authorization required, per project policy). On confirmation the folder
    becomes a repository and the flow proceeds as above. Without a repository there
    is no Space.
- **Add a workspace** — `git worktree add` on a chosen branch/base creates a
  **linked** workspace (unchanged from base §8).
- **Remove a Space** — **non-destructive**. Casper removes the Space from
  `session.json` and releases its workspaces' reserved ports. The repository, its
  linked worktrees, and its branches are **left intact on disk**. Casper never
  deletes the user's data on a Space removal.

## 6. Workspace diff summary

Each workspace row shows a compact summary of its Git changes.

- **What it counts:** the **branch's divergence from its base** — the diff between
  the workspace branch and the **merge-base** of that branch and `baseBranch` (the
  reference branch, e.g. `main`), **commits included**. This reflects the total size
  of the work in the
  workspace and stays stable after the agent commits. For the **primary** workspace
  on `main`, the base is `main` itself → typically `+0 / −0`.
- **Display:** `+<insertions>` in green and `−<deletions>` in red — **line counts
  only, no changed-file count**. Same +/- color convention as the diff viewer (base
  §11). When the diff is empty (`insertions == 0 && deletions == 0`) the summary is
  **hidden entirely** — no `+0 / −0` is shown. The **primary** workspace on `main`
  therefore typically shows no diff summary.
- **Source:** computed via libgit2's `git_diff` through `CasperGit` (structured
  stats, no text parsing), consistent with the diff viewer.
- **`diffStat` is derived, not persisted.** It is recomputed on Space/workspace open
  and refreshed on change. The refresh trigger (ideally `FSEvents` /
  `DispatchSource` on the worktree; otherwise on hook events or periodic) is an
  **implementation detail** to settle in the plan, not part of this spec.

## 7. Unchanged from the base design

- **Ports:** a contiguous 10-port block is reserved **per workspace** (`CASPER_PORT`,
  base §9), not per Space. A Space has no port block of its own.
- **Hooks:** hook installation is **global**, once in `~/.claude/settings.json`
  (base §7), unchanged by Spaces and **not** per workspace. Every workspace —
  primary included — still exports `CASPER_SOCKET` / `CASPER_WORKSPACE_ID` /
  `CASPER_PORT` in its terminal surfaces (per-surface runtime identity).
- **No `CASPER_PROJECT` env in v1** (YAGNI). The per-surface environment is unchanged.
- **Persistence:** `SessionStore` serializes the full `Session → Space → Workspace`
  tree (base §10). Each workspace's `portBase` is restored as-is; `diffStat` is not
  persisted (recomputed on load).

## 8. Out of scope

- State aggregation on the Space header (rolled-up badge / active count).
- Multi-repository Spaces (a Space is exactly one repository).
- Exposing Space identity to terminals (`CASPER_PROJECT`).
- Changed-file counts in the diff summary (lines only).
- Destructive Space removal (pruning worktrees / deleting branches).
