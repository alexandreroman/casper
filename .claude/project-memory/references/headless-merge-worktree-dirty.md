---
name: "Headless merge leaves the base worktree dirty"
description: "After mergeBranchHeadless, the base branch's worktree reports deleted files; decide any resync before merging"
type: reference
---

# Headless merge leaves the base worktree dirty

`Repository.mergeBranchHeadless` (CasperGit `Merge.swift`) advances the target
branch's ref without ever running `git_checkout`. The instant it returns, any
worktree that has the target branch checked out has HEAD ahead of its working
directory, so `git status` reports every merged file as `deleted:` and
`Repository.isClean()` returns `false` — even for a worktree the user never
touched.

**Why it matters:** any logic that inspects a base-branch worktree's cleanliness
to decide whether to act on it must read that cleanliness **before** calling the
merge. Checking `isClean()` afterwards always sees "dirty" and draws the wrong
conclusion. `AppModel.closeWorkspace` therefore checks both the workspace's and
the primary's worktree up front and refuses the close if either is dirty; the
post-merge `WorktreeManager.resyncWorkingTree` (force `git_checkout_head`) then
runs **unconditionally**, since the precondition already established that the
primary was clean.

**How to access:** see `Sources/CasperUI/AppModel.swift`
(`closeWorkspace`), `Sources/CasperGit/Merge.swift`
(`mergeBranchHeadless`, `forceCheckoutHead`), and
`Sources/CasperCore/WorktreeManager.swift` (`resyncWorkingTree`). Reproduce with:
`git commit-tree` a merge commit, `git update-ref refs/heads/<base> <oid>`
without checkout, then `git status --short` in that worktree shows `D <file>`.
