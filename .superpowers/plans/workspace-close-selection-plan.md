# Auto-Reselect on Workspace Close Implementation Plan

> **✅ DONE — shipped.** This plan is retained for reference; its task checkboxes
> are left unticked as historical record.

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a workspace is removed (deleted, closed/merged, or dropped along
with its whole Space), `AppModel.selectedWorkspaceID` moves to the first
remaining workspace in the same Space (display order), falling back to the first
workspace of the first remaining Space, instead of the current "always jump to
the global first workspace" behavior.

**Architecture:** Add one private helper, `fallbackSelection(preferring:)`, to
`AppModel`, and change the two existing selection-repair call sites
(`removeWorkspace`, `removeSpace`) to use it. Every removal path (CLI delete, UI
delete, UI close/merge, closing a workspace's last terminal pane) already
funnels through these two functions, so no other call site changes.

**Tech Stack:** Swift 6, XCTest (needs the full Xcode toolchain — see the
`test-toolchain` project-memory note: CLT alone can't link XCTest).

## Global Constraints

- Code lines wrap at 120 columns; Markdown at 80 (not applicable to this
  Swift-only change, noted for completeness).
- No comments explaining *what* code does — only ones capturing non-obvious
  *why* (existing file convention; match it in any new code).
- Tests require the full Xcode toolchain (`sudo xcode-select -s
  /Applications/Xcode.app`), not just the Command Line Tools.
- Full spec: [`workspace-close-selection.md`](workspace-close-selection.md).

---

### Task 1: Same-Space selection preference in `removeWorkspace`/`removeSpace`

**Files:**
- Modify: `Sources/CasperUI/AppModel.swift:362-373` (`removeSpace`),
  `Sources/CasperUI/AppModel.swift:465-479` (`removeWorkspace`)
- Test: `Tests/CasperUITests/AppModelTests.swift`

**Interfaces:**
- Produces: `private func fallbackSelection(preferring space: Space?) -> UUID?`
  on `AppModel` — internal to this task; no later task calls it directly.
- Consumes (all pre-existing, unchanged):
  - `Space.orderedWorkspaces: [Workspace]`
    (`Sources/CasperCore/Models.swift:375`)
  - `AppModel.spaces: [Space]`, `AppModel.selectedWorkspaceID: UUID?`
  - `AppModel.selectWorkspace(_ id: UUID?)` (`AppModel.swift:489`)
  - `AppModel.locate(_ id: UUID) -> (space: Int, workspace: Int)?`

- [ ] **Step 1: Write the failing test**

  In `Tests/CasperUITests/AppModelTests.swift`, insert immediately after
  `testRemovingSelectedLinkedWorkspaceReselectsValidWorkspace` (ends at line
  337, right before `testAddAfterRestoreDoesNotReuseRestoredPortBlock`):

  ```swift
  func testRemovingSelectedLinkedWorkspacePrefersSiblingInSameSpace() throws {
      let repo = try makeTempGitRepo()
      let (store, _) = makeStore()
      let model = AppModel(sessionStore: store)
      model.addSpace(folderURL: repo, probe: AppModel.gitProbe)
      let gitSpaceID = model.spaces[0].id
      _ = model.addLinkedWorkspace(spaceID: gitSpaceID, name: "Feature One")
      _ = model.addLinkedWorkspace(spaceID: gitSpaceID, name: "Feature Two")
      // Alphabetically before the repo's temp-dir name ("casper-test-…"), so
      // this Space becomes `spaces[0]` and the Git Space becomes `spaces[1]`.
      model.addSpace(folderURL: URL(fileURLWithPath: "/tmp/aaa-first-space"), probe: { _ in nil })

      XCTAssertEqual(model.spaces[0].name, "aaa-first-space")
      let gitSpace = try XCTUnwrap(model.spaces.first(where: { $0.id == gitSpaceID }))
      let featureTwoID = try XCTUnwrap(
          gitSpace.workspaces.first(where: { $0.branch == "feature-two" })?.id)
      let gitSpacePrimaryID = gitSpace.workspaces[0].id

      model.selectWorkspace(featureTwoID)
      model.removeWorkspace(id: featureTwoID)

      // Must land on the remaining workspace in the SAME Space (its primary,
      // since "feature-one" and the primary both sort after "feature-two" is
      // gone, and primary sorts first in display order) — not jump to the
      // alphabetically-first Space overall ("aaa-first-space"'s primary).
      XCTAssertEqual(model.selectedWorkspaceID, gitSpacePrimaryID)
  }
  ```

- [ ] **Step 2: Run the test to verify it fails**

  Run: `swift test --filter testRemovingSelectedLinkedWorkspacePrefersSiblingInSameSpace`

  Expected: FAIL. `removeWorkspace` still uses
  `selectWorkspace(spaces.first?.workspaces.first?.id)` — the global fallback —
  so `selectedWorkspaceID` resolves to `aaa-first-space`'s primary instead of
  `gitSpacePrimaryID`, and `XCTAssertEqual` reports the mismatch.

- [ ] **Step 3: Implement the fix**

  In `Sources/CasperUI/AppModel.swift`, add the helper directly above
  `removeSpace` (currently at line 362):

  ```swift
  /// The workspace selection should fall back to after a removal: the first
  /// remaining workspace of `space` in display order if it still has one,
  /// otherwise the first workspace of the first remaining Space overall.
  private func fallbackSelection(preferring space: Space?) -> UUID? {
      space?.orderedWorkspaces.first?.id ?? spaces.first?.orderedWorkspaces.first?.id
  }
  ```

  Change `removeSpace` (lines 369-371) from:

  ```swift
          if let sel = selectedWorkspaceID, removed.workspaces.contains(where: { $0.id == sel }) {
              selectWorkspace(spaces.first?.workspaces.first?.id)
          }
  ```

  to:

  ```swift
          if let sel = selectedWorkspaceID, removed.workspaces.contains(where: { $0.id == sel }) {
              selectWorkspace(fallbackSelection(preferring: nil))
          }
  ```

  Change `removeWorkspace` (lines 475-477) from:

  ```swift
          if selectedWorkspaceID == id {
              selectWorkspace(spaces.first?.workspaces.first?.id)
          }
  ```

  to:

  ```swift
          if selectedWorkspaceID == id {
              selectWorkspace(fallbackSelection(preferring: spaces[at.space]))
          }
  ```

  (`at.space` is already in scope from the `guard let at = locate(id)` at the
  top of `removeWorkspace`; `spaces[at.space]` is the Space the just-removed
  workspace belonged to, already mutated to exclude it.)

- [ ] **Step 4: Run the test to verify it passes**

  Run: `swift test --filter testRemovingSelectedLinkedWorkspacePrefersSiblingInSameSpace`

  Expected: PASS.

- [ ] **Step 5: Run the full suite to check for regressions**

  Run: `swift test --filter AppModelTests`

  Expected: PASS, including the three pre-existing selection tests
  (`testRemoveDeletesEntryAndFixesSelection`,
  `testRemovingSelectedSpaceLeavingNoneClearsSelection`,
  `testRemovingSelectedLinkedWorkspaceReselectsValidWorkspace`) unchanged — they
  only exercise degenerate cases (one remaining workspace, or zero Spaces left)
  where the old and new fallback logic agree.

- [ ] **Step 6: Commit**

  ```bash
  git add Sources/CasperUI/AppModel.swift Tests/CasperUITests/AppModelTests.swift
  git commit -m "Prefer a same-Space sibling when reselecting after a workspace removal"
  ```

---

### Task 2: Selection coverage for close/merge and delete-outright

**Files:**
- Modify: `Tests/CasperUITests/CloseDeleteWorkspaceTests.swift`

**Interfaces:**
- Consumes (all pre-existing, unchanged): `AppModel.closeWorkspace(id:) ->
  WorkspaceCloseOutcome` (`.success` case, `AppModel.swift:1578`),
  `AppModel.deleteWorkspace(id:) -> Result<Void, WorkspaceDeleteError>`
  (`AppModel.swift:1629`), `AppModel.selectWorkspace(_:)`,
  `AppModel.selectedWorkspaceID`, and the file's existing private helper
  `seededGitModel() -> (AppModel, UUID, String)`
  (`CloseDeleteWorkspaceTests.swift:82`).
- Produces: nothing consumed by a later task — this task only adds test
  coverage; `closeWorkspace`/`deleteWorkspace` already inherit Task 1's fix
  automatically (both funnel through `pruneWorkspaceFromDisk` →
  `removeWorkspace`).

Note on TDD framing: `seededGitModel()` creates only **one** Space, so in these
two tests the "same-Space sibling" and the "global fallback" resolve to the same
workspace (the sole Space's primary) — this scenario would already have passed
before Task 1's fix. These tests exist to close a real coverage gap
(`CloseDeleteWorkspaceTests.swift` currently has zero assertions on
`selectedWorkspaceID`), not to re-prove Task 1's fix. Expect both to pass on
first run.

- [ ] **Step 1: Write the test for `closeWorkspace`**

  In `Tests/CasperUITests/CloseDeleteWorkspaceTests.swift`, insert immediately
  after `testCloseWorkspaceMergesThenDeletesFromDisk` (ends at line 115, right
  before `testCloseWorkspaceAbortsOnConflictAndDeletesNothing`):

  ```swift
  func testCloseWorkspaceReselectsPrimaryWhenClosingSelectedLinkedWorkspace() throws {
      let (model, primaryID, _) = try seededGitModel()
      guard case .success(let created) = model.createLinkedWorkspace(
          spaceID: try XCTUnwrap(model.space(for: try XCTUnwrap(model.workspace(id: primaryID)))?.id),
          name: "feature", base: nil)
      else { return XCTFail("setup failed") }
      try commitFile(atPath: created.worktreePath, filename: "feature.txt", content: "new\n")
      model.selectWorkspace(created.id)

      XCTAssertEqual(model.closeWorkspace(id: created.id), .success)

      XCTAssertEqual(model.selectedWorkspaceID, primaryID)
  }
  ```

- [ ] **Step 2: Write the test for `deleteWorkspace`**

  Insert immediately after `testDeleteWorkspaceSkipsMergeAndDeletesFromDisk`
  (ends at line 154, right before
  `testCloseWorkspaceResyncsCleanPrimaryWorktree`):

  ```swift
  func testDeleteWorkspaceReselectsPrimaryWhenDeletingSelectedLinkedWorkspace() throws {
      let (model, primaryID, _) = try seededGitModel()
      guard case .success(let created) = model.createLinkedWorkspace(
          spaceID: try XCTUnwrap(model.space(for: try XCTUnwrap(model.workspace(id: primaryID)))?.id),
          name: "feature", base: nil)
      else { return XCTFail("setup failed") }
      model.selectWorkspace(created.id)

      guard case .success = model.deleteWorkspace(id: created.id) else {
          return XCTFail("expected delete to succeed")
      }

      XCTAssertEqual(model.selectedWorkspaceID, primaryID)
  }
  ```

- [ ] **Step 3: Run both new tests to verify they pass**

  Run: `swift test --filter CloseDeleteWorkspaceTests`

  Expected: PASS — all tests in the file, including the two new ones.

- [ ] **Step 4: Run the full suite**

  Run: `swift test`

  Expected: PASS, full suite green (no regressions from either task).

- [ ] **Step 5: Commit**

  ```bash
  git add Tests/CasperUITests/CloseDeleteWorkspaceTests.swift
  git commit -m "Add selection coverage for closeWorkspace/deleteWorkspace"
  ```

- [ ] **Step 6: Manual verification**

  Run `make dev` to launch the app. Add a Git-backed folder as a Space, then add
  two linked workspaces to it (sidebar per-Space "+"). Select one of the two
  linked workspaces, then delete it ("Delete Workspace…" from its sidebar
  context menu). Confirm the sidebar's selection highlight moves to the other
  workspace remaining in that *same* Space (not to an unrelated Space, if more
  than one Space is open). Repeat with "Merge and Close Workspace…" on a
  workspace with a clean worktree and a mergeable branch. The `debug-casper`
  skill's `dump-state`/`screenshot` verbs can capture evidence of the
  before/after selection if a written record is wanted.

## Spec Coverage Check

- "First choice: first remaining workspace in the same Space" → Task 1,
  `removeWorkspace`'s `fallbackSelection(preferring: spaces[at.space])`.
- "Fallback: first workspace of the first Space, if the closed workspace's Space
  has no other workspaces left" → Task 1, `fallbackSelection`'s `??
  spaces.first?.orderedWorkspaces.first?.id` branch, and `removeSpace`'s
  `fallbackSelection(preferring: nil)` (the Space is gone, so it always takes
  this branch).
- "Ordering = display order, consistently" → Task 1 uses `orderedWorkspaces` in
  both branches of `fallbackSelection`.
- "Closing a non-selected workspace never changes selection" → unchanged guard
  conditions (`if selectedWorkspaceID == id` /
  `if let sel = selectedWorkspaceID, removed.workspaces.contains(...)`) in both
  functions — no task touches this, verified by the untouched existing tests
  continuing to pass in Task 1 Step 5.
- "CLI delete / UI delete / UI close-merge, all covered" → all funnel through
  `removeWorkspace`/`removeSpace` (see design doc's summary table); Task 1 fixes
  the shared root, Task 2 adds direct-path regression coverage for the
  close/merge and delete-outright entry points specifically.
