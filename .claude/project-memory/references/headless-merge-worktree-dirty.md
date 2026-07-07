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
to decide whether to act on it (e.g. `AppModel.closeWorkspace`'s post-merge
resync of the sibling worktree) must capture that cleanliness **before** calling
the merge. Checking `isClean()` after the merge always sees "dirty" and wrongly
skips. This bit Task 5: the resync is now gated on a pre-merge
`cleanBaseBranchWorktree(baseBranch:in:)` snapshot, and the mechanical
`WorktreeManager.resyncWorkingTree` (force `git_checkout_head`) runs afterward.

**How to access:** see `Sources/CasperUI/AppModel.swift`
(`closeWorkspace` + `cleanBaseBranchWorktree`), `Sources/CasperGit/Merge.swift`
(`mergeBranchHeadless`, `forceCheckoutHead`), and
`Sources/CasperCore/WorktreeManager.swift` (`resyncWorkingTree`). Reproduce with:
`git commit-tree` a merge commit, `git update-ref refs/heads/<base> <oid>`
without checkout, then `git status --short` in that worktree shows `D <file>`.
