# Theme: Git & Worktrees (CasperGit)

**Modules:** CasperGit + Clibgit2 + CSigbusGuard · **Status:** ✅ built (see
`../status.md`) · **Code:** `Sources/CasperGit/`, `Sources/Clibgit2/`,
`Sources/CSigbusGuard/`

A thin in-house Swift wrapper over the **libgit2** C API — no external `git`
binary. We own this surface; it exposes only what Casper needs.

## Design

- **`Clibgit2`** — a `.systemLibrary` binding libgit2 via Homebrew + pkg-config
  (dynamic link; `make bundle` embeds the dylib chain with dylibbundler). Build
  host needs `brew install libgit2 pkgconf`.
- **`CSigbusGuard`** — a small C target wrapping the three libgit2 calls that
  read memory-mapped working-directory files in a `SIGBUS` guard: the
  working-tree diff and the status walk behind `isClean`
  (`Sources/CasperGit/Repository.swift`), and the force checkout of HEAD
  (`Sources/CasperGit/Merge.swift`). libgit2 mmaps blobs, so a file **truncated
  while one of those runs** faults the whole process; the guard `siglongjmp`s
  out of the faulting thread back into `CasperGit`, which turns it into a thrown
  error the UI can report. The jump buffer is `_Thread_local` because concurrent
  diffs run on several cooperative-pool threads and the handler executes on the
  faulting one. A `SIGBUS` raised *outside* a guarded region restores the
  default disposition and re-executes the instruction, so a genuine crash still
  produces a genuine crash report. See [[sigbus-guard-diff]].
- **`Repository`** — `initialize`/`open` (an **exact** path: either a working
  tree's root or its `.git` directory, which is what lets `mainWorkingTree()`
  open a common dir directly; there is deliberately no
  `git_repository_discover` wrapper, so a path that is neither is an error
  rather than a silent walk up the tree), branch queries (head, existence,
  checked-out), worktree add/list/lookup/prune, status/isClean, and Git ignore
  checks (`isPathIgnored`, `ignoredTopLevelDirectories` over
  `git_ignore_path_is_ignored` — used to keep high-churn ignored dirs out of the
  filesystem watcher, `app-ui.md`). `WorktreeInfo`, `GitError`.
- **Repository identity** — `isBare`, `commonDirPath` (the `.git` directory
  every working tree of a repository shares, and so the repository's identity)
  and `isLinkedWorktree`, plus **`mainWorkingTree()`**, which opens that common
  directory to reach the main repository and returns its workdir. That is what
  lets a linked worktree opened on its own pull its repository in rather than
  standing alone. This layer only *reports* — `isBare`, and a `path` libgit2 is
  not guaranteed to have derived from a working tree of this repository. The two
  refusals built on those facts (a bare repository, and a main working tree that
  does not resolve to a folder of the same repository) live one layer up, in
  CasperUI's Space probing (see `space-project.md`).
- **`fileTextAtHead(path:)`** — the HEAD side of a file, read by the diff
  service.
- **Worktree model** — creating a workspace = `addWorktree`, which **always
  creates a new branch**, named after the worktree, at the resolved base commit
  (`basedOn` — a branch, tag or commit-ish — or HEAD), and only then
  `git_worktree_add`s the worktree checked out to that new branch. An existing
  branch is never adopted, and a failure after the branch exists rolls back the
  branch and the admin entry it created, so retrying the same name is idempotent
  rather than `GIT_EEXISTS`. An admin entry that predates the call belongs to
  another worktree registered under that name and is left untouched, folder
  included; `WorktreeManager.create` refuses such a name up front
  (`WorktreeError.Reason.worktreeNameTaken`). The check fires on any entry —
  a live worktree, one whose folder was deleted without a prune, or a partial
  leftover — so the message says only that Git already has a worktree entry by
  that name, and points at `git worktree prune` for a deleted one, rather than
  showing libgit2's "directory exists". Then a plain Ghostty terminal opens in
  its folder.
  Cleanliness is read through `git_status_list_new` (`isClean`), and a failure
  at any step is surfaced as a clear UI error, never a crash. There is no
  `git_worktree_validate` wrapper: libgit2 reports the failure directly from the
  operation being attempted, so a second validating call would only duplicate
  it.
- **Diff — ✅ built for working-tree-vs-HEAD.** `Repository.diffWorkdirToHead()`
  returns a structured `GitDiff` (files → hunks → lines, statuses, binary flag,
  `insertions`/`deletions`) — no text parsing — feeding the diff viewer
  (`app-ui.md`). The types live in `Sources/CasperGit/Diff.swift`. Renames are
  detected (`git_diff_find_similar`, untracked files included, so a plain `mv`
  pairs up too) within git's default budget of 1000² candidate pairs; a file
  over the diff's 8 MB cap never pairs, and copy detection is off. The pass
  lives in `Sources/CasperGit/RenameDetection.swift`. A file the diff lists but
  cannot open (a mode-000 file) has no patch: it is listed with the
  `unreadable` status and no hunks, and the rest of the diff is unaffected.

- **Merge — ✅ built.** `Repository.mergeBranchHeadless(…)` performs the
  worktree-free merge behind "Merge and Close Workspace…", returning a
  `MergeOutcome` and surfacing `MergeConflictError` (an unrelated history is a
  `GitError` saying so); `forceCheckoutHead()` is its recovery path.
  The merge commit is written under the user's own Git identity and never an
  invented one: with no usable identity it throws
  `MissingCommitterIdentityError` before writing anything.
  `WorktreeManager.merge` maps both refusals into `WorktreeError`
  (`.mergeConflict`, `.missingCommitterIdentity`), as it does every libgit2
  failure, and "Merge and Close" shows the identity one's message — libgit2's
  cause, then the remedy ("Commit identity" below) — with nothing deleted. The
  cause matters because a configuration libgit2 cannot read fails the same way
  as a missing identity. An up-to-date merge writes no commit and
  needs no identity. See `Sources/CasperGit/Merge.swift`.

- **Commit identity.** Both commits Casper writes — the merge above and a new
  Space's initial commit (`space-project.md`) — take their author and committer
  from `git_signature_default_from_env`. Each field is resolved on its own: the
  author's name and email from `GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL`, the
  committer's from `GIT_COMMITTER_NAME` / `GIT_COMMITTER_EMAIL`, falling back
  to `user.name` / `user.email`, and to `EMAIL` when `user.email` is not set at
  all; `GIT_AUTHOR_DATE` / `GIT_COMMITTER_DATE` replace the current time. A
  blank value is refused, not skipped, and unlike `git` libgit2 never guesses a
  `user@host` address. The environment that counts is the Casper app process's
  own, never an agent shell's inside a Casper terminal: it holds a shell's
  variables when that shell runs Casper's executable directly
  (`Casper.app/Contents/MacOS/casper`, `make dev`, and the tests), while
  `open`, the Finder and the Dock hand Casper launchd's environment, which
  `launchctl setenv` extends. A set variable shadows the configuration even
  when blank, so the refusal message depends on the cause. When variables are
  to blame — a `GIT_*_NAME` or `GIT_*_EMAIL` libgit2 rejects, or a
  `GIT_*_DATE` it cannot parse, as listed in
  `MissingCommitterIdentityError.environmentVariables` — the message names
  them and says to correct or unset them where Casper is started. Otherwise it
  names the two `git config` commands, the remedy that works however Casper
  was launched. It gives both remedies when a variable is to blame and a
  setting is missing as well (`settingMissing`: libgit2 returned
  `GIT_ENOTFOUND` for `user.name` or `user.email`), and says `git config`
  cannot help only when nothing else is to blame. The diagnosis resolves the
  author and the committer again, each on its own, so a date is blamed only
  on the side that fails on it. libgit2 records no error for an unparsable
  date, except the stale "`user.email` was not found" its `EMAIL` fallback
  leaves behind; a genuine miss returns `GIT_ENOTFOUND` rather than -1, which
  tells the two apart.

Interop gotchas (variadic `_v` functions, pointer lifecycle, error codes) are
captured in the [[libgit2-swift-interop]] project-memory note.

## Standing limitations

- `WorktreeManager.remove` prunes a worktree without deleting its branch. Its
  one production caller deletes the branch on the next line, so recreating a
  same-named workspace works; a caller that forgets would meet an opaque
  `.gitFailure`.
