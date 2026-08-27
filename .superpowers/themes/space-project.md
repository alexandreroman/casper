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

A **Space** sits between `Session` and `Workspace` and always has **≥ 1
workspace**: exactly one **primary** and 0..n **linked** (each a
`git worktree add`). For a Git repository the primary is the repo's main
working tree, typically `main`. A folder that is not a repository is a
**degenerate** Space — one primary workspace, no worktree creation — and is
promoted the moment its folder gains a `.git`. *Invariant: one Space per
repository, always ≥ 1 workspace.*

- **Naming** — default from the `origin` remote's last path segment without
  `.git` (fallback: the root folder name). Renamable; a renamed Space stops
  tracking the folder/remote.
- **Lifecycle** — a Space begins one of two ways. **Adoption** opens a folder
  that already exists; **creation** (`AppModel.createSpace(at:probe:)`) makes
  the folder, runs `Repository.initialize` in it, and then hands it to adoption,
  so the two paths converge and only one of them assembles a Space. A folder
  that is not a repository opens as a degenerate Space rather than prompting for
  anything, and `AppModel.promoteSpaceIfGitInitialized` promotes it once a
  `.git` appears. Add a workspace via `git worktree add`; **remove is
  non-destructive** (drops the Space from `session.json` and releases ports;
  leaves the repo, worktrees, and branches on disk).

A created Space is an ordinary one from the first frame — a full Git Space with
a single primary workspace — and its repository holds exactly one commit: an
**empty initial commit** (`Repository.createInitialCommit`), no files in it.
That commit is what lets a workspace be created in the Space straight away,
since `git worktree add` checks the new worktree out at a commit resolved
through HEAD, and a repository with no commits leaves HEAD unborn — resolving
to nothing, which `WorktreeError.Reason.repositoryHasNoCommits` reports in
Casper's own words. A Space can still be rooted at a repository whose HEAD is
unborn: one adopted before its first commit, or one whose initial commit was
skipped because the machine configures no committer identity (Casper never
invents one). `Repository.headBranchName()` reads the branch from HEAD's
symbolic target when there is no commit to resolve, so the primary workspace is
named after the real branch (`main`, or whatever `init.defaultBranch` says)
instead of falling back to the folder name. Creation refuses any path that is
already taken — Casper never deletes or overwrites what it did not create; see
`app-ui.md` § Design → "Ways into a Space" for the panel and the refusal rules.

### Space identity — one Space per repository

Identity is the common `.git` directory every working tree of a repository
shares, not a path. Three rules keep it 1:1, and the point of all three is that
a repository is never represented twice:

- **Adoption.** A folder that is a linked worktree of a repository *already
  open* joins that Space as a linked workspace instead of becoming a Space of
  its own. Nothing is created on disk, so no `setup` hook runs.
- **Pull-in.** A folder that is a linked worktree of a repository *not open*
  pulls that repository in rather than standing alone. The Space roots at the
  repository's **main working tree**, built exactly as opening that folder
  would build it, and the folder the user actually picked joins it as a linked
  workspace named after its branch, with the primary's branch as its
  `baseBranch` — and it is the one selected, being what the user chose. The
  main working tree is resolved through `CasperGit`'s `mainWorkingTree()`.
- **Reunification.** Opening a repository whose worktrees are *already open as
  Spaces* folds them into the Space it creates, moving those workspaces whole —
  ids, ports, layouts and live terminals unchanged — with each ex-primary
  becoming a linked workspace named after its branch.

Two layouts are **refused outright**, with an alert and nothing added: a
worktree of a **bare** repository, which has no main working tree and never
will; and one whose main working tree does not resolve to a folder of the *same*
repository — the repository directory gone from disk, or a `--separate-git-dir`
layout, where libgit2 answers the git directory's parent, an unrelated folder a
same-repository guard rejects. There is deliberately **no silent fallback** to a
Space rooted at the worktree: that is precisely the shape these rules exist to
prevent.

Re-adding a folder Casper already tracks only selects it.

### Data model changes (vs `architecture.md`)

- `repoPath` **moves up** from `Workspace` to `Space` (one repo per Space).
- `Workspace` gains `kind: primary | linked` and `baseBranch`.
  `LayoutNode`/`Surface`/`Todo`/`AgentState` unchanged.

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
legacy files), not the migration the original plan described. The three identity
rules above and their two refusals are built (`AppModel+Spaces.swift`), as is
creation from scratch (`AppModel.createSpace`, same file).

Remaining for this theme: **Space rename** only. The per-workspace `+/−` diff
summary is **dropped** (see the top note), so the divergence stats it needed —
a `diffStat` on `Workspace`, branch-vs-merge-base line counts in `CasperGit` —
were never built and are not planned. See [[space-diff-summary-dropped]] for the
rationale.
