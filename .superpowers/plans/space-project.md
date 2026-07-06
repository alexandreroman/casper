# Space (Project) & Workspace Diff Summary — Implementation Plan

> **⚠️ SUPERSEDED (2026-07-06) — do not execute.** The Space model, remote-URL
> read, and repo-name derivation (Tasks 1–3, 5, 6) already landed with CasperUI
> UI-2. The **workspace diff summary is dropped** (decision 2026-07-06), so the
> divergence-stats and diff-helper tasks (Task 4, Task 7) are moot. The only
> Space work still open is **Space rename**, which this plan does not cover. This
> file is retained for historical reference. See `../status.md` and
> `../themes/space-project.md`.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Per the project convention ([[implementation-workflow]]), dispatch **one `skillbox:code-writer` per task**, review between tasks, and commit per task.

**Goal:** Add the CasperCore + CasperGit substrate for the **Space (project)** concept and the **per-workspace branch-divergence diff summary**, fully unit-tested, ready for the Plan 5 sidebar to consume.

**Architecture:** Insert a `Space` level between `Session` and `Workspace` (a Space is one Git repository; it owns `repoPath`, which moves off `Workspace`). Each `Workspace` gains a `kind` (`primary | linked`) and a `baseBranch`. Repo-name derivation and Space assembly are pure/composed helpers in CasperCore; the +/− line counts come from a new libgit2 tree-to-tree divergence computation in CasperGit. The diff summary is **derived on demand** (`WorktreeManager.diffStat`), never persisted.

**Tech Stack:** Swift 6 / SwiftPM, XCTest, libgit2 via the `Clibgit2` module map behind `CasperGit`.

**Scope boundary — deferred to Plan 5 (CasperUI):** the collapsible Space header and workspace rows, rendering the green/red counts, hiding an empty summary, the `git init` confirmation flow, and the FSEvents/hook refresh trigger that recomputes `diffStat`. This plan stops at the tested model + git substrate those consume.

## Global Constraints

- Swift 6, macOS 14+, **arm64-only**. Line length: code 120 cols, Markdown 80 cols.
- Only sanctioned deps: GhosttyKit, swift-argument-parser, libgit2. **Add none.**
- All generated text (code, comments, docs) in **English, present tense** ([[english-only]]).
- Tests use **XCTest** and need the full Xcode toolchain
  (`sudo xcode-select -s /Applications/Xcode.app`); run with `swift test`.
- Every `git commit` message is **verb + action performed, in English**
  ([[commit-message-style]]) and ends with the trailer:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- `diffStat` is **derived, never persisted** (spec §6): realized as the
  `WorktreeManager.diffStat(...)` function, not a stored `Workspace` field.
- A Space maps 1:1 to a Git repository; a Space always has exactly one
  `primary` workspace and 0..n `linked` ones (spec §2).

---

## File Structure

- `Sources/CasperCore/Models.swift` — add `Space`, `DiffStat`; change `Session`
  (`workspaces` → `spaces`), `Workspace` (add `kind`, `baseBranch`; **remove**
  `repoPath`).
- `Sources/CasperCore/Space.swift` *(new)* — `SpaceNaming` (pure name
  derivation), `SpaceError`, `SpaceManager.open`, and the
  `WorktreeManager.diffStat` extension.
- `Sources/CasperGit/Repository.swift` — add `remoteURL(named:)`.
- `Sources/CasperGit/Diff.swift` *(new)* — `Repository.divergenceLineStats`.
- Tests: `Tests/CasperGitTests/DiffTests.swift` *(new)*,
  `Tests/CasperCoreTests/SpaceTests.swift` *(new)*, and updates to
  `ModelsTests.swift` / `SessionStoreTests.swift` plus the mechanical call-site
  fixes below.

---

## Task 1: Model refactor — Space, Session.spaces, Workspace kind/baseBranch, DiffStat

A type refactor is atomic: `Session`/`Workspace` change and every construction
site must compile together, so this is one task.

**Files:**
- Modify: `Sources/CasperCore/Models.swift`
- Test: `Tests/CasperCoreTests/ModelsTests.swift`
- Mechanical call-site fixes (drop `repoPath:`, nesting): `Tests/CasperCoreTests/SessionStoreTests.swift`, `Tests/CasperCoreTests/AgentStateReducerTests.swift`, `Tests/CasperCoreTests/AgentStateStoreTests.swift`, `Tests/CasperCoreTests/ProgressTests.swift`, `Tests/CasperCLITests/EndToEndHookTests.swift`

**Interfaces:**
- Produces:
  - `Session(spaces: [Space] = [])`, `Session.spaces: [Space]`
  - `Space(id: UUID = UUID(), name: String, repoPath: String, workspaces: [Workspace] = [])`, `Identifiable`
  - `Workspace.Kind` = `.primary | .linked` (`String`-backed `Codable`)
  - `Workspace(id:name:kind:.linked default,worktreePath:branch:baseBranch:String? = nil,agentState:.idle,todos:[],pendingNotification:false,portBase:layout:)` — **no `repoPath`**; `baseBranch` defaults to `branch` when `nil`
  - `DiffStat(insertions: Int, deletions: Int)` with `var isEmpty: Bool`

- [ ] **Step 1: Rewrite the ModelsTests sample to the nested shape (failing test)**

Replace the body of `Tests/CasperCoreTests/ModelsTests.swift` with:

```swift
import Foundation
import XCTest
@testable import CasperCore

final class ModelsTests: XCTestCase {
    private func sampleSession() -> Session {
        let term = Surface(kind: .terminal(cwd: "/repo/wt", command: nil))
        let browser = Surface(kind: .browser(url: URL(string: "http://localhost:40000")!))
        let diff = Surface(kind: .diff(againstHead: true))
        let layout = LayoutNode.split(
            orientation: .horizontal,
            children: [
                .tabGroup(surfaces: [term, browser], activeIndex: 0),
                .tabGroup(surfaces: [diff], activeIndex: 0),
            ],
            ratios: [0.6, 0.4]
        )
        let primary = Workspace(
            name: "main", kind: .primary,
            worktreePath: "/repo", branch: "main", baseBranch: "main",
            portBase: 40000, layout: .tabGroup(surfaces: [], activeIndex: 0)
        )
        let feature = Workspace(
            name: "feat-x", kind: .linked,
            worktreePath: "/repo/wt", branch: "feat-x", baseBranch: "main",
            agentState: .working,
            todos: [Todo(content: "wire up", status: .inProgress)],
            pendingNotification: false, portBase: 40010, layout: layout
        )
        let space = Space(name: "repo", repoPath: "/repo", workspaces: [primary, feature])
        return Session(spaces: [space])
    }

    func testSessionCodableRoundTrip() throws {
        let original = sampleSession()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Session.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testWorkspaceKindRawValues() {
        XCTAssertEqual(Workspace.Kind.primary.rawValue, "primary")
        XCTAssertEqual(Workspace.Kind.linked.rawValue, "linked")
    }

    func testBaseBranchDefaultsToOwnBranch() {
        let ws = Workspace(
            name: "w", worktreePath: "/r", branch: "topic",
            portBase: 40000, layout: .tabGroup(surfaces: [], activeIndex: 0))
        XCTAssertEqual(ws.baseBranch, "topic")
    }

    func testDiffStatIsEmpty() {
        XCTAssertTrue(DiffStat(insertions: 0, deletions: 0).isEmpty)
        XCTAssertFalse(DiffStat(insertions: 1, deletions: 0).isEmpty)
    }

    func testTodoStatusRawValuesMatchClaudeCode() {
        XCTAssertEqual(TodoStatus.pending.rawValue, "pending")
        XCTAssertEqual(TodoStatus.inProgress.rawValue, "in_progress")
        XCTAssertEqual(TodoStatus.completed.rawValue, "completed")
    }
}
```

- [ ] **Step 2: Run it to confirm it fails to compile**

Run: `swift test --filter CasperCoreTests.ModelsTests`
Expected: build failure — `Space` unknown, `Workspace` has no `kind`/`baseBranch`, `Session` has no `spaces`.

- [ ] **Step 3: Rewrite the model in `Sources/CasperCore/Models.swift`**

Replace the `Workspace` and `Session` structs (lines 47–89) with, and add `DiffStat`:

```swift
public struct DiffStat: Codable, Equatable, Sendable {
    public var insertions: Int
    public var deletions: Int
    public init(insertions: Int, deletions: Int) {
        self.insertions = insertions
        self.deletions = deletions
    }
    /// Empty when nothing diverged; the sidebar hides an empty summary (spec §6).
    public var isEmpty: Bool { insertions == 0 && deletions == 0 }
}

public struct Workspace: Codable, Equatable, Identifiable, Sendable {
    /// Whether this workspace is the repository's main working tree (`primary`)
    /// or an added `git worktree` (`linked`).
    public enum Kind: String, Codable, Sendable {
        case primary, linked
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    public var worktreePath: String
    public var branch: String
    /// Reference branch the diff summary diverges from, e.g. `main` (spec §6).
    public var baseBranch: String
    public var agentState: AgentState
    public var todos: [Todo]
    public var pendingNotification: Bool
    public var portBase: Int
    public var layout: LayoutNode

    public init(
        id: UUID = UUID(),
        name: String,
        kind: Kind = .linked,
        worktreePath: String,
        branch: String,
        baseBranch: String? = nil,
        agentState: AgentState = .idle,
        todos: [Todo] = [],
        pendingNotification: Bool = false,
        portBase: Int,
        layout: LayoutNode
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.worktreePath = worktreePath
        self.branch = branch
        self.baseBranch = baseBranch ?? branch
        self.agentState = agentState
        self.todos = todos
        self.pendingNotification = pendingNotification
        self.portBase = portBase
        self.layout = layout
    }
}

/// A Space is one Git repository. It always holds exactly one `primary`
/// workspace (the repo's main working tree) and 0..n `linked` ones (spec §2).
public struct Space: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var repoPath: String
    public var workspaces: [Workspace]

    public init(
        id: UUID = UUID(),
        name: String,
        repoPath: String,
        workspaces: [Workspace] = []
    ) {
        self.id = id
        self.name = name
        self.repoPath = repoPath
        self.workspaces = workspaces
    }
}

public struct Session: Codable, Equatable, Sendable {
    public var spaces: [Space]
    public init(spaces: [Space] = []) {
        self.spaces = spaces
    }
}
```

- [ ] **Step 4: Fix the mechanical call sites so the package compiles**

In each file below, every `Workspace(...)` literal must **drop the `repoPath:`
argument** (the property no longer exists). No other change is needed there;
`kind` and `baseBranch` have defaults. Files and their `Workspace(...)` counts:
`Tests/CasperCoreTests/AgentStateReducerTests.swift` (8),
`Tests/CasperCoreTests/AgentStateStoreTests.swift` (13),
`Tests/CasperCoreTests/ProgressTests.swift` (1),
`Tests/CasperCLITests/EndToEndHookTests.swift` (1).

In `Tests/CasperCoreTests/SessionStoreTests.swift`, `testSaveThenLoadRoundTrips`
builds a `Session(workspaces: [...])`. Replace it with a Space-nested session:

```swift
    func testSaveThenLoadRoundTrips() throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = SessionStore(fileURL: url)

        let session = Session(spaces: [
            Space(name: "r", repoPath: "/r", workspaces: [
                Workspace(
                    name: "w", worktreePath: "/r/w", branch: "b",
                    portBase: 40000, layout: .tabGroup(surfaces: [], activeIndex: 0)
                )
            ])
        ])
        try store.save(session)
        XCTAssertEqual(try store.load(), session)
    }
```

Run: `swift build --disable-automatic-resolution 2>&1 | grep -i error` — iterate
until it prints nothing. (If any test file still passes `repoPath:`, the compiler
names the file and line.)

- [ ] **Step 5: Run the model tests to verify they pass**

Run: `swift test --filter CasperCoreTests.ModelsTests`
Expected: PASS (4 test methods + the round-trip).

- [ ] **Step 6: Run the full suite to confirm no regressions from the refactor**

Run: `swift test`
Expected: PASS (all prior tests, now on the nested shape).

- [ ] **Step 7: Commit**

```bash
git add Sources/CasperCore/Models.swift Tests/
git commit -m "$(cat <<'EOF'
Introduce Space model and primary/linked workspace kind

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: SessionStore migration — old-shape files self-heal

The on-disk schema changed (`workspaces` → nested `spaces`). Old files must not
crash startup. `SessionStore.load()` already backs up an undecodable file and
returns an empty `Session`; this task pins that behavior for the schema change
with a regression test. No production code change is expected.

**Files:**
- Test: `Tests/CasperCoreTests/SessionStoreTests.swift`

**Interfaces:**
- Consumes: `SessionStore.load()` (Task 1's `Session`).

- [ ] **Step 1: Add the failing regression test**

Append to `SessionStoreTests`:

```swift
    func testLoadPreSpaceSchemaSelfHeals() throws {
        let url = tempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A session.json from before the Space refactor: top-level "workspaces",
        // each carrying the removed "repoPath". It no longer decodes.
        let legacy = Data("""
        { "workspaces": [ { "id": "00000000-0000-0000-0000-000000000000",
          "name": "w", "repoPath": "/r", "worktreePath": "/r/w", "branch": "b",
          "agentState": "idle", "todos": [], "pendingNotification": false,
          "portBase": 40000,
          "layout": { "tabGroup": { "surfaces": [], "activeIndex": 0 } } } ] }
        """.utf8)
        try legacy.write(to: url)

        let store = SessionStore(fileURL: url)
        XCTAssertEqual(try store.load(), Session())
        let backupURL = url.appendingPathExtension("corrupt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
    }
```

- [ ] **Step 2: Run it to verify it passes (behavior already present)**

Run: `swift test --filter CasperCoreTests.SessionStoreTests.testLoadPreSpaceSchemaSelfHeals`
Expected: PASS — the legacy file is undecodable under the new schema, so `load()`
self-heals and moves it aside. If instead it FAILS because the legacy JSON
decoded, adjust the fixture so it cannot (the missing `spaces` key already
guarantees a decode failure).

- [ ] **Step 3: Commit**

```bash
git add Tests/CasperCoreTests/SessionStoreTests.swift
git commit -m "$(cat <<'EOF'
Cover pre-Space session.json self-healing on load

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: CasperGit — read the origin remote URL

**Files:**
- Modify: `Sources/CasperGit/Repository.swift` (add a method to the `Repository` class, after `isClean()` ~line 146)
- Test: `Tests/CasperGitTests/RepositoryTests.swift`

**Interfaces:**
- Produces: `Repository.remoteURL(named: String = "origin") throws -> String?` — `nil` when the remote is absent.

- [ ] **Step 1: Write the failing test**

Add to `Tests/CasperGitTests/RepositoryTests.swift` (use the existing `GitFixture`
pattern; create a temp repo, set an `origin` remote via libgit2):

```swift
    func testRemoteURLReturnsNilWithoutRemote() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("casper-remote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try GitFixture.repository(at: dir.path)
        XCTAssertNil(try repo.remoteURL())
    }

    func testRemoteURLReturnsConfiguredOrigin() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("casper-remote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try GitFixture.repository(at: dir.path)

        var remote: OpaquePointer?
        try gitCheck(git_remote_create(
            &remote, repo.pointer, "origin",
            "https://github.com/alexandreroman/my-app.git"))
        git_remote_free(remote)

        XCTAssertEqual(
            try repo.remoteURL(), "https://github.com/alexandreroman/my-app.git")
    }
```

Ensure the file has `import Clibgit2` and `@testable import CasperGit` at the top
(add them if missing).

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter CasperGitTests.RepositoryTests.testRemoteURLReturnsConfiguredOrigin`
Expected: build failure — `remoteURL` is not a member of `Repository`.

- [ ] **Step 3: Implement `remoteURL(named:)`**

Add inside the `Repository` class in `Sources/CasperGit/Repository.swift`:

```swift
    /// The URL configured for remote `name` (default `origin`), or `nil` when no
    /// such remote exists.
    public func remoteURL(named name: String = "origin") throws -> String? {
        var remote: OpaquePointer?
        let code = git_remote_lookup(&remote, pointer, name)
        defer { git_remote_free(remote) }
        if code == GIT_ENOTFOUND.rawValue { return nil }
        try gitCheck(code)
        guard let cURL = git_remote_url(remote) else { return nil }
        return String(cString: cURL)
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter CasperGitTests.RepositoryTests`
Expected: PASS (both new tests + existing).

- [ ] **Step 5: Commit**

```bash
git add Sources/CasperGit/Repository.swift Tests/CasperGitTests/RepositoryTests.swift
git commit -m "$(cat <<'EOF'
Add Repository.remoteURL to read the origin remote

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: CasperGit — branch-divergence line stats

Counts insertions/deletions of a branch relative to its merge-base with a base
branch (three-dot divergence, commits included), via tree-to-tree diff stats.

**Files:**
- Create: `Sources/CasperGit/Diff.swift`
- Test: `Tests/CasperGitTests/DiffTests.swift`

**Interfaces:**
- Consumes: `Repository` (from CasperGit); `git_merge_base`, `git_diff_tree_to_tree`, `git_diff_get_stats`.
- Produces: `Repository.divergenceLineStats(branch: String, base: String) throws -> (insertions: Int, deletions: Int)` — `(0, 0)` when the branch equals its base / has not diverged.

- [ ] **Step 1: Write the failing test**

Create `Tests/CasperGitTests/DiffTests.swift`:

```swift
import XCTest
import Clibgit2
@testable import CasperGit

final class DiffTests: XCTestCase {
    private func tempDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("casper-diff-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Commit `contents` to `file` on the current HEAD branch and return nothing.
    private func commit(_ contents: String, to file: String, in repo: Repository, message: String) throws {
        let path = repo.workdirPath!
        try contents.write(
            to: URL(fileURLWithPath: path).appendingPathComponent(file),
            atomically: true, encoding: .utf8)
        var index: OpaquePointer?
        try gitCheck(git_repository_index(&index, repo.pointer))
        defer { git_index_free(index) }
        try gitCheck(git_index_add_bypath(index, file))
        try gitCheck(git_index_write(index))
        var treeOid = git_oid()
        try gitCheck(git_index_write_tree(&treeOid, index))
        var tree: OpaquePointer?
        try gitCheck(git_tree_lookup(&tree, repo.pointer, &treeOid))
        defer { git_tree_free(tree) }
        var sig: UnsafeMutablePointer<git_signature>?
        try gitCheck(git_signature_now(&sig, "T", "t@casper.local"))
        defer { git_signature_free(sig) }
        var parent: OpaquePointer?
        var head: OpaquePointer?
        if git_repository_head(&head, repo.pointer) == 0 {
            git_reference_free(head)
            var parentOid = git_oid()
            try gitCheck(git_reference_name_to_id(&parentOid, repo.pointer, "HEAD"))
            try gitCheck(git_commit_lookup(&parent, repo.pointer, &parentOid))
        }
        defer { git_commit_free(parent) }
        var commitOid = git_oid()
        let parents: [OpaquePointer?] = parent == nil ? [] : [parent]
        try parents.withUnsafeBufferPointer { buf in
            try gitCheck(git_commit_create(
                &commitOid, repo.pointer, "HEAD", sig, sig, nil, message, tree,
                parents.count, buf.baseAddress.map { UnsafeMutablePointer(mutating: $0) }))
        }
    }

    func testNoDivergenceIsZero() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try GitFixture.repository(at: dir.path)
        let branch = try repo.headBranchName()
        let stats = try repo.divergenceLineStats(branch: branch, base: branch)
        XCTAssertEqual(stats.insertions, 0)
        XCTAssertEqual(stats.deletions, 0)
    }

    func testCountsInsertionsOnDivergedBranch() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try GitFixture.repository(at: dir.path)
        let base = try repo.headBranchName()

        // Create a branch off HEAD and add two committed lines on it.
        let wt = try repo.addWorktree(
            name: "feature",
            atPath: dir.appendingPathComponent("feature-wt").path, basedOn: base)
        let branchRepo = try Repository.open(atPath: wt.path)
        try commit("line one\nline two\n", to: "notes.txt", in: branchRepo, message: "add notes")

        let stats = try repo.divergenceLineStats(branch: "feature", base: base)
        XCTAssertEqual(stats.insertions, 2)
        XCTAssertEqual(stats.deletions, 0)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter CasperGitTests.DiffTests`
Expected: build failure — `divergenceLineStats` is undefined.

- [ ] **Step 3: Implement the divergence computation**

Create `Sources/CasperGit/Diff.swift`:

```swift
import Clibgit2
import Foundation

extension Repository {
    /// Added/removed line counts of `branch` relative to its merge-base with
    /// `base` (three-dot divergence, commits included). Returns `(0, 0)` when the
    /// branch has not diverged. Compares committed history only; working-tree and
    /// untracked changes are not counted.
    public func divergenceLineStats(
        branch: String, base: String
    ) throws -> (insertions: Int, deletions: Int) {
        var branchOid = try commitOid(revspec: branch)
        var baseOid = try commitOid(revspec: base)

        // Merge-base tree; unrelated histories → diff against the empty tree.
        var mergeBaseOid = git_oid()
        let mbCode = git_merge_base(&mergeBaseOid, pointer, &branchOid, &baseOid)
        var ancestorTree: OpaquePointer?
        if mbCode == 0 {
            ancestorTree = try tree(forCommitOid: mergeBaseOid)
        } else if mbCode != GIT_ENOTFOUND.rawValue {
            try gitCheck(mbCode)
        }
        defer { git_tree_free(ancestorTree) }

        let branchTree = try tree(forCommitOid: branchOid)
        defer { git_tree_free(branchTree) }

        var diff: OpaquePointer?
        try gitCheck(git_diff_tree_to_tree(
            &diff, pointer, ancestorTree, branchTree, nil))
        defer { git_diff_free(diff) }

        var stats: OpaquePointer?
        try gitCheck(git_diff_get_stats(&stats, diff))
        defer { git_diff_stats_free(stats) }

        return (
            insertions: Int(git_diff_stats_insertions(stats)),
            deletions: Int(git_diff_stats_deletions(stats)))
    }

    /// Peel a revspec (branch/tag/oid) to its commit OID.
    private func commitOid(revspec: String) throws -> git_oid {
        var object: OpaquePointer?
        try gitCheck(git_revparse_single(&object, pointer, revspec))
        defer { git_object_free(object) }
        var commit: OpaquePointer?
        try gitCheck(git_object_peel(&commit, object, GIT_OBJECT_COMMIT))
        defer { git_object_free(commit) }
        return git_commit_id(commit).pointee
    }

    /// The tree of the commit identified by `oid` (caller frees it).
    private func tree(forCommitOid oid: git_oid) throws -> OpaquePointer? {
        var oidVar = oid
        var commit: OpaquePointer?
        try gitCheck(git_commit_lookup(&commit, pointer, &oidVar))
        defer { git_commit_free(commit) }
        var tree: OpaquePointer?
        try gitCheck(git_commit_tree(&tree, commit))
        return tree
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter CasperGitTests.DiffTests`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CasperGit/Diff.swift Tests/CasperGitTests/DiffTests.swift
git commit -m "$(cat <<'EOF'
Add branch-divergence line stats via tree-to-tree diff

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: CasperCore — repo-name derivation (pure)

**Files:**
- Create: `Sources/CasperCore/Space.swift`
- Test: `Tests/CasperCoreTests/SpaceTests.swift`

**Interfaces:**
- Produces: `enum SpaceNaming { static func defaultName(remoteURL: String?, folderName: String) -> String }` — last URL segment without a trailing `.git`; falls back to `folderName` when there is no remote or the URL yields no name.

- [ ] **Step 1: Write the failing test**

Create `Tests/CasperCoreTests/SpaceTests.swift`:

```swift
import Foundation
import XCTest
@testable import CasperCore

final class SpaceTests: XCTestCase {
    func testDefaultNameFromHTTPSRemote() {
        XCTAssertEqual(
            SpaceNaming.defaultName(
                remoteURL: "https://github.com/alexandreroman/my-app.git",
                folderName: "checkout"),
            "my-app")
    }

    func testDefaultNameFromScpRemote() {
        XCTAssertEqual(
            SpaceNaming.defaultName(
                remoteURL: "git@github.com:alexandreroman/my-app.git",
                folderName: "checkout"),
            "my-app")
    }

    func testDefaultNameFromRemoteWithoutGitSuffix() {
        XCTAssertEqual(
            SpaceNaming.defaultName(
                remoteURL: "https://github.com/alexandreroman/my-app",
                folderName: "checkout"),
            "my-app")
    }

    func testDefaultNameFallsBackToFolderWithoutRemote() {
        XCTAssertEqual(
            SpaceNaming.defaultName(remoteURL: nil, folderName: "checkout"),
            "checkout")
    }

    func testDefaultNameFallsBackToFolderForEmptyRemote() {
        XCTAssertEqual(
            SpaceNaming.defaultName(remoteURL: "", folderName: "checkout"),
            "checkout")
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter CasperCoreTests.SpaceTests`
Expected: build failure — `SpaceNaming` is undefined.

- [ ] **Step 3: Implement `SpaceNaming`**

Create `Sources/CasperCore/Space.swift`:

```swift
import CasperGit
import Foundation

/// Default naming for a Space, derived from its repository (spec §2.1).
public enum SpaceNaming {
    /// The last path segment of `remoteURL` without a trailing `.git`; falls
    /// back to `folderName` when there is no remote or no name can be derived.
    public static func defaultName(remoteURL: String?, folderName: String) -> String {
        guard let remoteURL, let name = repoName(fromRemoteURL: remoteURL) else {
            return folderName
        }
        return name
    }

    static func repoName(fromRemoteURL url: String) -> String? {
        var text = url
        while text.hasSuffix("/") { text.removeLast() }
        // Last segment after a '/' (URL) or ':' (scp-like git@host:owner/repo).
        let separators = CharacterSet(charactersIn: "/:")
        let segment: String
        if let sep = text.rangeOfCharacter(from: separators, options: .backwards) {
            segment = String(text[text.index(after: sep.lowerBound)...])
        } else {
            segment = text
        }
        let name = segment.hasSuffix(".git") ? String(segment.dropLast(4)) : segment
        return name.isEmpty ? nil : name
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter CasperCoreTests.SpaceTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CasperCore/Space.swift Tests/CasperCoreTests/SpaceTests.swift
git commit -m "$(cat <<'EOF'
Derive default Space name from the repository remote

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: CasperCore — assemble a Space with its primary workspace

**Files:**
- Modify: `Sources/CasperCore/Space.swift`
- Test: `Tests/CasperCoreTests/SpaceTests.swift`

**Interfaces:**
- Consumes: `Repository.open/workdirPath/headBranchName/remoteURL` (CasperGit); `SpaceNaming.defaultName` (Task 5).
- Produces:
  - `struct SpaceError: Error, Equatable { enum Reason { case repositoryNotFound, gitFailure(String) }; let reason: Reason }`
  - `enum SpaceManager { static func open(repoPath: String, portBase: Int) throws -> Space }` — opens an existing repo, returns a Space with one `.primary` workspace on the repo's main working tree (`branch = baseBranch = HEAD`, a single-terminal layout). The caller supplies the port block.

- [ ] **Step 1: Write the failing test**

Add to `Tests/CasperCoreTests/SpaceTests.swift` (import CasperGit for the fixture):

```swift
    func testOpenBuildsPrimaryWorkspace() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("casper-space-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try CasperGit.Repository.repositoryFixture(at: dir.path)

        let space = try SpaceManager.open(repoPath: dir.path, portBase: 40000)

        XCTAssertEqual(space.workspaces.count, 1)
        let primary = space.workspaces[0]
        XCTAssertEqual(primary.kind, .primary)
        XCTAssertEqual(primary.baseBranch, primary.branch)
        XCTAssertEqual(primary.portBase, 40000)
        // Falls back to the folder name (fixture has no remote).
        XCTAssertEqual(space.name, dir.lastPathComponent)
    }

    func testOpenNonRepositoryThrowsRepositoryNotFound() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("casper-nonrepo-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertThrowsError(try SpaceManager.open(repoPath: dir.path, portBase: 40000)) {
            XCTAssertEqual(($0 as? SpaceError)?.reason, .repositoryNotFound)
        }
    }
```

This test needs a repo fixture reachable from CasperCoreTests. `GitFixture` lives
in the CasperGitTests target and is not importable here. Add a tiny public
fixture helper to CasperGit for reuse:

In `Sources/CasperGit/Repository.swift`, add:

```swift
extension Repository {
    /// Test/support helper: initialize a repo at `path` with one commit on the
    /// default branch. Public so other packages' tests can build a real repo
    /// without shelling out to `git`.
    @discardableResult
    public static func repositoryFixture(at path: String) throws -> Repository {
        let repo = try initialize(atPath: path)
        let readme = URL(fileURLWithPath: path).appendingPathComponent("README.md")
        try "casper fixture\n".write(to: readme, atomically: true, encoding: .utf8)
        var index: OpaquePointer?
        try gitCheck(git_repository_index(&index, repo.pointer))
        defer { git_index_free(index) }
        try gitCheck(git_index_add_bypath(index, "README.md"))
        try gitCheck(git_index_write(index))
        var treeOid = git_oid()
        try gitCheck(git_index_write_tree(&treeOid, index))
        var tree: OpaquePointer?
        try gitCheck(git_tree_lookup(&tree, repo.pointer, &treeOid))
        defer { git_tree_free(tree) }
        var sig: UnsafeMutablePointer<git_signature>?
        try gitCheck(git_signature_now(&sig, "Casper Test", "test@casper.local"))
        defer { git_signature_free(sig) }
        var commitOid = git_oid()
        try gitCheck(git_commit_create(
            &commitOid, repo.pointer, "HEAD", sig, sig, nil, "Initial commit", tree, 0, nil))
        return repo
    }
}
```

Add `import Clibgit2` at the top of `Repository.swift` if not already present
(it is — line 1). Then have `Tests/CasperGitTests/GitFixture.swift`'s
`GitFixture.repository(at:)` delegate to it to avoid duplication:

```swift
    @discardableResult
    static func repository(at path: String) throws -> Repository {
        try Repository.repositoryFixture(at: path)
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter CasperCoreTests.SpaceTests.testOpenBuildsPrimaryWorkspace`
Expected: build failure — `SpaceManager` / `SpaceError` undefined.

- [ ] **Step 3: Implement `SpaceError` and `SpaceManager.open`**

Append to `Sources/CasperCore/Space.swift`:

```swift
/// A Space-open failure in Casper's own vocabulary (never a raw libgit2 code).
public struct SpaceError: Error, Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case repositoryNotFound
        case gitFailure(String)
    }
    public let reason: Reason
    public init(_ reason: Reason) { self.reason = reason }
}

/// Assembles a `Space` from a Git repository (spec §2, §5).
public enum SpaceManager {
    /// Open an existing repository at `repoPath` and build a `Space` containing
    /// its `primary` workspace (the repo's main working tree). `portBase` is the
    /// caller-allocated 10-port block for that workspace.
    public static func open(repoPath: String, portBase: Int) throws -> Space {
        let repo: Repository
        do { repo = try Repository.open(atPath: repoPath) }
        catch { throw SpaceError(.repositoryNotFound) }

        let workdir = repo.workdirPath ?? repoPath
        let branch: String
        let remoteURL: String?
        do {
            branch = try repo.headBranchName()
            remoteURL = try repo.remoteURL()
        } catch let gitError as GitError {
            throw SpaceError(.gitFailure(gitError.message))
        }

        let folderName = URL(fileURLWithPath: workdir).lastPathComponent
        let name = SpaceNaming.defaultName(remoteURL: remoteURL, folderName: folderName)

        let primary = Workspace(
            name: branch,
            kind: .primary,
            worktreePath: workdir,
            branch: branch,
            baseBranch: branch,
            portBase: portBase,
            layout: .tabGroup(
                surfaces: [Surface(kind: .terminal(cwd: workdir, command: nil))],
                activeIndex: 0))

        return Space(name: name, repoPath: workdir, workspaces: [primary])
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter CasperCoreTests.SpaceTests`
Expected: PASS (all 7 SpaceTests). Also run `swift test --filter CasperGitTests`
to confirm the fixture refactor didn't regress.

- [ ] **Step 5: Commit**

```bash
git add Sources/CasperCore/Space.swift Sources/CasperGit/Repository.swift Tests/
git commit -m "$(cat <<'EOF'
Assemble a Space with its primary workspace from a repo

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: CasperCore — the workspace diff summary helper

Wraps Task 4's git divergence into a `DiffStat`, in Casper's error vocabulary.
This is the on-demand value the Plan 5 sidebar calls per workspace.

**Files:**
- Modify: `Sources/CasperCore/Space.swift`
- Test: `Tests/CasperCoreTests/SpaceTests.swift`

**Interfaces:**
- Consumes: `Repository.divergenceLineStats` (Task 4); `DiffStat` (Task 1).
- Produces: `extension WorktreeManager { static func diffStat(repoPath: String, branch: String, baseBranch: String) throws -> DiffStat }` — `.isEmpty` when the branch has not diverged (the sidebar hides it then).

- [ ] **Step 1: Write the failing test**

Add to `Tests/CasperCoreTests/SpaceTests.swift`:

```swift
    func testDiffStatIsEmptyForPrimaryOnBase() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("casper-diffstat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try CasperGit.Repository.repositoryFixture(at: dir.path)
        let branch = try repo.headBranchName()

        let stat = try WorktreeManager.diffStat(
            repoPath: dir.path, branch: branch, baseBranch: branch)
        XCTAssertTrue(stat.isEmpty)
    }

    func testDiffStatOnMissingRepositoryThrows() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("casper-nodiff-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertThrowsError(try WorktreeManager.diffStat(
            repoPath: dir.path, branch: "main", baseBranch: "main")) {
            XCTAssertEqual(($0 as? WorktreeError)?.reason, .repositoryNotFound)
        }
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter CasperCoreTests.SpaceTests.testDiffStatIsEmptyForPrimaryOnBase`
Expected: build failure — `WorktreeManager.diffStat` is undefined.

- [ ] **Step 3: Implement the helper**

Append to `Sources/CasperCore/Space.swift`:

```swift
extension WorktreeManager {
    /// The branch-divergence line summary for a workspace, as a `DiffStat`.
    /// `.isEmpty` is true when the branch has not diverged from `baseBranch`
    /// (spec §6); the sidebar hides an empty summary. Committed history only.
    public static func diffStat(
        repoPath: String, branch: String, baseBranch: String
    ) throws -> DiffStat {
        let repo: Repository
        do { repo = try Repository.open(atPath: repoPath) }
        catch { throw WorktreeError(.repositoryNotFound) }
        do {
            let stats = try repo.divergenceLineStats(branch: branch, base: baseBranch)
            return DiffStat(insertions: stats.insertions, deletions: stats.deletions)
        } catch let gitError as GitError {
            throw WorktreeError(.gitFailure(gitError.message))
        }
    }
}
```

- [ ] **Step 4: Run the full suite to verify everything passes**

Run: `swift test`
Expected: PASS — all prior tests plus the new SpaceTests. Confirms the whole
substrate builds and is green.

- [ ] **Step 5: Commit**

```bash
git add Sources/CasperCore/Space.swift Tests/CasperCoreTests/SpaceTests.swift
git commit -m "$(cat <<'EOF'
Expose workspace diff summary via WorktreeManager.diffStat

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage:**
- §2 Space = Git repo, ≥1 primary workspace → Task 1 (`Space`, `Workspace.Kind`), Task 6 (`SpaceManager.open`). ✓
- §2.1 Naming (remote last segment sans `.git`; folder fallback; renamable) → Task 5 (`SpaceNaming`); renamable = `Space.name` is a `var`. ✓
- §3 Data model (`repoPath` moves up; `kind`; `baseBranch`; `diffStat` derived) → Task 1; `diffStat` realized as a function in Task 7 (documented in Global Constraints). ✓
- §4 Sidebar → **deferred to Plan 5** (stated in scope boundary); substrate consumed: `Space`, `Workspace`, `DiffStat`, `diffStat()`. ✓
- §5 Lifecycle: open → Task 6; `git init` for a non-repo folder = UI (Plan 5); add-workspace = existing `WorktreeManager.create` (unchanged); non-destructive removal = UI drops the `Space` from `Session` + releases ports (pure model already supports it — `Session.spaces` is a `var`). ✓
- §6 Diff summary (branch vs merge-base of base; +/− lines only; hidden when empty; libgit2, no parsing; derived) → Task 4 (git), Task 7 (`diffStat`), `DiffStat.isEmpty` for hiding. ✓
- §7 Unchanged (ports per workspace, hooks global, no `CASPER_PROJECT`, persistence tree) → `portBase` stays on `Workspace`; Task 2 covers persistence migration. ✓
- §10 Persistence / migration of old files → Task 2. ✓

**Placeholder scan:** none — every step carries real code and exact commands.

**Type consistency:** `DiffStat(insertions:deletions:)`, `Workspace.Kind.primary/.linked`, `Space(name:repoPath:workspaces:)`, `Session(spaces:)`, `SpaceError.Reason.repositoryNotFound`, `WorktreeError.Reason.repositoryNotFound`, `Repository.remoteURL(named:)`, `Repository.divergenceLineStats(branch:base:)`, `Repository.repositoryFixture(at:)`, `SpaceManager.open(repoPath:portBase:)`, `WorktreeManager.diffStat(repoPath:branch:baseBranch:)` — all defined once and referenced consistently across tasks.
