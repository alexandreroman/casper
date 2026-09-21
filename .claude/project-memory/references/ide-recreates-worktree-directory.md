---
name: "An IDE re-creates a deleted worktree directory"
description: "IntelliJ writes .idea/* back into a closed workspace's path minutes later; worktree creation reclaims such leftovers"
type: reference
---

# An IDE re-creates a deleted worktree directory

Closing a workspace deletes its worktree directory correctly. An IDE that still
holds that worktree open as a project re-creates the directory **two to five
minutes later**, writing nothing into it but its own metadata
(`.idea/workspace.xml` and siblings) — no `.git`, no project files. Observed
with IntelliJ IDEA on three separate merges.

**Why:** the ghost directory is inert, but it occupies the path the next
workspace of the same name wants, which would otherwise push that workspace onto
a `-2` sibling (`repo-jev-2` for a workspace named `jev`). The user-visible
damage is the name, not the leftover — a report of "Merge and Close failed to
delete the folder" is this, not a deletion bug.

**How to access:** `WorktreeManager.claimWorktreePath` and
`isDisposableLeftover` (`Sources/CasperCore/WorktreeManager.swift`) carry the
reclaim rule and the allow-list of metadata names it tolerates;
`AppModel.availableWorktreePath` is the caller. Regression tests: the
`…IsDisposable` / `…ClaimWorktreePath…` cases in
`Tests/CasperCoreTests/WorktreeManagerTests.swift`, and
`testAddLinkedWorkspaceReclaimsAnEditorLeftoverDirectory` in
`Tests/CasperUITests/AppModelTests.swift`.
