# Theme: Space (Project)

**Status:** ◐ (see `../status.md`) · **Extends** `../architecture.md` (data
model, sidebar, worktrees, persistence).

Promotes the sidebar's implicit "group by repository" into a first-class
**Space**. The Space grouping ships with the CasperUI sidebar (`app-ui.md`).

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
  `.git` (fallback: the root folder name). Renaming is **intended, not built**
  — it is the one item this theme has left: a renamed Space is to stop tracking
  the folder/remote.
- **Lifecycle** — a Space begins one of two ways. **Adoption** opens a folder
  that already exists; **creation** (`AppModel.createSpace(at:probe:)`) makes
  the folder, runs `Repository.initialize` in it, and then hands it to adoption,
  so the two paths converge and only one of them assembles a Space. A folder
  that is not a repository opens as a degenerate Space rather than prompting for
  anything, and `AppModel.promoteSpaceIfGitInitialized` promotes it once a
  `.git` appears — seen live by the filesystem watcher, and once per Space at
  launch — and demotes it back if the `.git` is removed. A **workspace** is
  added with `git worktree add`, at a visible sibling of the repository folder,
  `<parent>/<repo>-<branch>` — outside the repo, so untracked with no exclude
  entry, and with a `-2`/`-3`… suffix when the name is taken — and removed
  destructively: closing or deleting one prunes its worktree — the folder and
  all — and then deletes its branch. Removing a **Space** is the non-destructive
  operation, and the only one: it drops the Space from `session.json` and
  releases its ports, leaving the repo, its worktrees and its branches on disk.

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
symbolic target when there is no commit to resolve, so the primary workspace's
row still shows the real branch (`main`, or whatever `init.defaultBranch` says)
instead of falling back to a name. A row renders `Workspace.branchLabel`, which
is the branch when there is one and the workspace's `name` only when there is
not — and a primary workspace's `name` is the Space's own name, never its
branch. Creation refuses any path that is already taken — Casper never deletes
or overwrites what it did not create — the one exception being a directory
holding nothing but a `.DS_Store`, which is exactly what the save panel's own
**New Folder** button hands over; see `app-ui.md` § Design → "Ways into a Space"
for the panel and the refusal rules.

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
  Should that main working tree already be tracked by an open Space — which
  happens when the Space's runtime-only `isGitRepo` flag was never resolved —
  the picked folder is **adopted** into it by the rule above, rather than
  rooting a second Space at the same folder.
- **Reunification.** Opening a repository whose worktrees are *already open as
  Spaces* folds them into the Space it creates, moving those workspaces whole —
  ids, ports, layouts and live terminals unchanged — with each ex-primary
  becoming a linked workspace named after its branch. The one exception is a
  workspace rooted at the absorbing Space's own working tree: it is **retired**
  rather than moved, since it would otherwise become a linked workspace whose
  deletion takes the repository itself with it.

Two layouts are **refused outright**, with an alert and nothing added: a
worktree of a **bare** repository, which has no main working tree and never
will; and one whose main working tree does not resolve to a folder of the *same*
repository — the repository directory gone from disk, or a `--separate-git-dir`
layout, where libgit2 answers the git directory's parent, an unrelated folder a
same-repository guard rejects. There is deliberately **no silent fallback** to a
Space rooted at the worktree: that is precisely the shape these rules exist to
prevent.

Re-adding a folder Casper already tracks only selects it.

### Sidebar

Each Space is a **collapsible group header** (repo name + chevron), **no state
aggregation** — agent state stays on the workspace rows; the primary is listed
first, then the linked workspaces by name. The Spaces themselves are ordered
alphabetically, `AppModel.spaces` being kept sorted so every reader inherits
that order for free. An expanded Git Space's header carries a trailing **"+"**
button that creates a linked workspace.

A collapsed Space hides its workspace rows, so whenever a row has to be
revealed the owning Space expands: the selection restored at launch, a
selection, an agent notification, and a newly created workspace (whichever path
created it). Publishing info (`casper info set`) deliberately does not expand
anything — it is a passive act with no claim on the user's attention.

## Unchanged from the base design

Ports stay **per workspace** (`CASPER_PORT`, injected in `linked` workspaces
only), not per Space, and there is no `CASPER_PROJECT`. Persistence: see
`core.md` § Design → "`SessionStore`".
