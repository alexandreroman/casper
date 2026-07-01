# CasperGit + WorktreeManager Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `CasperGit`, an in-house thin Swift wrapper over the libgit2 C
API (repository open/init, branch queries, worktree add/list/lookup/prune,
status), and `WorktreeManager` in `CasperCore` that orchestrates those
primitives into workspace-creation operations that never crash.

**Architecture:** Three new pieces in the existing `Casper` SwiftPM package: a
`Clibgit2` **systemLibrary** target (module map over Homebrew's libgit2, resolved
via pkg-config), a `CasperGit` Swift target that owns all C-pointer lifecycle and
error mapping and returns plain value types, and a `WorktreeManager` enum added
to `CasperCore` (which now depends on `CasperGit`) that maps libgit2 primitives
onto `CasperCore` domain errors. Dependency direction is
`CasperCore → CasperGit → Clibgit2 → libgit2`, exactly as the design spec §3.2
prescribes. `CasperGit` never imports `CasperCore`.

**Tech Stack:** Swift 6 / SwiftPM, XCTest, libgit2 1.9.4 (Homebrew, dynamically
linked via pkg-config), Foundation. `git_diff`, static linking/vendoring, and any
UI are **out of scope** — deferred to later plans.

## Global Constraints

- **Platform:** macOS 14+, **arm64-only**. `Package.swift` keeps
  `platforms: [.macOS(.v14)]`.
- **Swift tools version:** `6.0` (toolchain 6.3.3 present).
- **Allowed externals only:** this plan adds **libgit2** (the third and last
  allowed external). No new SwiftPM package dependencies — `Clibgit2` is a
  systemLibrary, not a fetched package. **No external `git` binary** in product
  *or* test code: fixtures are built through libgit2 itself.
- **libgit2 linking:** dynamic, via Homebrew + pkg-config (`.systemLibrary(...,
  pkgConfig: "libgit2", providers: [.brew(["libgit2"])])`). Switching to a
  vendored static `.a` is deferred to the packaging plan.
- **libgit2 version:** 1.9.x C API. Only stable, long-standing symbols are used.
- **Prerequisites (dev + CI):** `brew install libgit2 pkgconf` (pkgconf provides
  the `pkg-config` binary SwiftPM invokes). Tests still need the full Xcode
  toolchain (`sudo xcode-select -s /Applications/Xcode.app`), same as Plan 1.
- **Concurrency:** C-pointer-owning wrapper types (`Repository`, `Worktree`) are
  `final class`, **not** `Sendable`. Result value types (`WorktreeInfo`,
  `FileStatus`, `CreatedWorktree`) are `Sendable` structs.
- **Naming:** module `CasperGit`; system target `Clibgit2`; orchestration enum
  `WorktreeManager` in `CasperCore`.
- **Line length:** code 120 columns; Markdown 80. All identifiers/comments in
  English.

---

## File Structure

**Create:**
- `Sources/Clibgit2/module.modulemap` — system module map for libgit2.
- `Sources/Clibgit2/shim.h` — umbrella that includes `<git2.h>`.
- `Sources/CasperGit/Libgit2.swift` — one-time init, `GitError`, `gitCheck`,
  `git_strarray`/`git_buf` helpers.
- `Sources/CasperGit/Repository.swift` — `Repository` class: open/discover/init,
  `path`/`workdir`, head branch, branch existence & checked-out queries, status.
- `Sources/CasperGit/Worktree.swift` — `WorktreeInfo` + worktree
  add/list/info/prune/validate on `Repository`.
- `Sources/CasperCore/WorktreeManager.swift` — `WorktreeManager` enum +
  `WorktreeError` + `CreatedWorktree`.
- `Tests/CasperGitTests/GitFixture.swift` — test helper: init a repo with one
  commit, using `Clibgit2` directly.
- `Tests/CasperGitTests/RepositoryTests.swift`
- `Tests/CasperGitTests/WorktreeTests.swift`
- `Tests/CasperCoreTests/WorktreeManagerTests.swift`

**Modify:**
- `Package.swift` — add `Clibgit2`, `CasperGit`, `CasperGitTests`; make
  `CasperCore` depend on `CasperGit`; expose `CasperGit` product.
- `.github/workflows/ci.yml` — `brew install libgit2 pkgconf` before build.
- `Makefile` — document the libgit2 prerequisite in the header comment.
- `CLAUDE.md` — note the libgit2/pkgconf prerequisite under Build & run.

---

## Task 1: Clibgit2 system module + package wiring

**Files:**
- Create: `Sources/Clibgit2/module.modulemap`, `Sources/Clibgit2/shim.h`
- Modify: `Package.swift`
- Test: `Tests/CasperGitTests/RepositoryTests.swift` (smoke only, replaced later)

**Interfaces:**
- Produces: a `CasperGit` module that can `import Clibgit2` and call libgit2 C
  symbols (`git_libgit2_version`, `git_libgit2_init`, …).

- [ ] **Step 1: Create the module map**

`Sources/Clibgit2/module.modulemap`:

```
module Clibgit2 [system] {
    header "shim.h"
    link "git2"
    export *
}
```

- [ ] **Step 2: Create the umbrella shim header**

`Sources/Clibgit2/shim.h`:

```c
#ifndef CLIBGIT2_SHIM_H
#define CLIBGIT2_SHIM_H
#include <git2.h>
#endif
```

- [ ] **Step 3: Wire the targets in Package.swift**

Replace the whole `Package.swift` with:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Casper",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CasperCore", targets: ["CasperCore"]),
        .library(name: "CasperGit", targets: ["CasperGit"]),
    ],
    targets: [
        .systemLibrary(
            name: "Clibgit2",
            pkgConfig: "libgit2",
            providers: [.brew(["libgit2"])]
        ),
        .target(name: "CasperGit", dependencies: ["Clibgit2"]),
        .target(name: "CasperCore", dependencies: ["CasperGit"]),
        .testTarget(
            name: "CasperGitTests",
            dependencies: ["CasperGit", "Clibgit2"]
        ),
        .testTarget(name: "CasperCoreTests", dependencies: ["CasperCore"]),
    ]
)
```

- [ ] **Step 4: Add a temporary smoke test**

`Tests/CasperGitTests/RepositoryTests.swift`:

```swift
import XCTest
import Clibgit2

final class Clibgit2SmokeTests: XCTestCase {
    func testLibgit2VersionIsLinked() {
        var major: Int32 = 0, minor: Int32 = 0, rev: Int32 = 0
        git_libgit2_version(&major, &minor, &rev)
        XCTAssertEqual(major, 1)
        XCTAssertGreaterThanOrEqual(minor, 9)
    }
}
```

- [ ] **Step 5: Build and run the smoke test**

Run: `swift build && swift test --filter Clibgit2SmokeTests`
Expected: PASS. (If pkg-config cannot find libgit2, run
`brew install libgit2 pkgconf` first.)

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/Clibgit2 Tests/CasperGitTests/RepositoryTests.swift
git commit -m "Add the Clibgit2 system module and wire CasperGit targets"
```

---

## Task 2: Libgit2 init, GitError, and low-level helpers

**Files:**
- Create: `Sources/CasperGit/Libgit2.swift`
- Test: `Tests/CasperGitTests/Libgit2Tests.swift`

**Interfaces:**
- Produces:
  - `enum Libgit2 { static func ensureInit() }` — idempotent, process-wide.
  - `struct GitError: Error, Equatable { let code: Int32; let message: String }`.
  - `@discardableResult func gitCheck(_ code: Int32) throws -> Int32` — throws
    `GitError` on negative return, reading `git_error_last()`.
  - `func gitStringArray(_ body: (inout git_strarray) throws -> Void) rethrows
    -> [String]` — runs `body`, copies out Swift strings, disposes.

- [ ] **Step 1: Write the failing test**

`Tests/CasperGitTests/Libgit2Tests.swift`:

```swift
import XCTest
import Clibgit2
@testable import CasperGit

final class Libgit2Tests: XCTestCase {
    func testEnsureInitIsIdempotent() {
        Libgit2.ensureInit()
        Libgit2.ensureInit()  // must not crash or over-init
        XCTAssertTrue(true)
    }

    func testGitCheckThrowsOnNegativeCode() {
        // Force a known failure: open a non-existent repo.
        Libgit2.ensureInit()
        var repo: OpaquePointer?
        let code = git_repository_open(&repo, "/nonexistent/casper/repo")
        XCTAssertLessThan(code, 0)
        XCTAssertThrowsError(try gitCheck(code)) { error in
            guard let gitError = error as? GitError else {
                return XCTFail("expected GitError, got \(error)")
            }
            XCTAssertEqual(gitError.code, code)
            XCTAssertFalse(gitError.message.isEmpty)
        }
    }

    func testGitCheckReturnsCodeOnSuccess() throws {
        XCTAssertEqual(try gitCheck(0), 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter Libgit2Tests`
Expected: FAIL to compile — `Libgit2`, `gitCheck`, `GitError` undefined.

- [ ] **Step 3: Implement Libgit2.swift**

`Sources/CasperGit/Libgit2.swift`:

```swift
import Clibgit2
import Foundation

/// Process-wide libgit2 initialization. `git_libgit2_init` is reference-counted
/// by libgit2; we call it exactly once and never shut down (acceptable for a
/// long-lived app and for the test process).
public enum Libgit2 {
    private static let initialized: Bool = {
        git_libgit2_init() >= 0
    }()

    /// Ensure libgit2 is initialized. Safe to call repeatedly.
    public static func ensureInit() {
        precondition(initialized, "git_libgit2_init failed")
    }
}

/// A libgit2 error: the raw negative return code plus the thread-local message.
public struct GitError: Error, Equatable {
    public let code: Int32
    public let message: String

    public init(code: Int32, message: String) {
        self.code = code
        self.message = message
    }
}

/// Throw a `GitError` when a libgit2 call returns a negative code; otherwise
/// return the (non-negative) code unchanged.
@discardableResult
func gitCheck(_ code: Int32) throws -> Int32 {
    guard code < 0 else { return code }
    let message: String
    if let last = git_error_last(), let cString = last.pointee.message {
        message = String(cString: cString)
    } else {
        message = "libgit2 error \(code)"
    }
    throw GitError(code: code, message: message)
}

/// Run `body` against a zeroed `git_strarray`, copy the entries into a Swift
/// array, and dispose the native array. `body` typically fills it via a libgit2
/// `*_list` call.
func gitStringArray(_ body: (inout git_strarray) throws -> Void) rethrows -> [String] {
    var array = git_strarray()
    try body(&array)
    defer { git_strarray_dispose(&array) }
    var result: [String] = []
    result.reserveCapacity(array.count)
    for index in 0..<array.count {
        if let cString = array.strings[index] {
            result.append(String(cString: cString))
        }
    }
    return result
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter Libgit2Tests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CasperGit/Libgit2.swift Tests/CasperGitTests/Libgit2Tests.swift
git commit -m "Add libgit2 init, GitError, and string-array helpers"
```

---

## Task 3: Repository open / discover / init and paths

**Files:**
- Create: `Sources/CasperGit/Repository.swift`
- Test: `Tests/CasperGitTests/RepositoryTests.swift` (replace the smoke file)

**Interfaces:**
- Consumes: `Libgit2.ensureInit()`, `gitCheck`.
- Produces:
  - `final class Repository`
  - `static func Repository.initialize(atPath:) throws -> Repository`
  - `static func Repository.open(atPath:) throws -> Repository`
  - `static func Repository.discover(startingAt:) throws -> Repository`
  - `var Repository.gitDirPath: String`
  - `var Repository.workdirPath: String?`
  - `let Repository.pointer: OpaquePointer` (internal, for other CasperGit files)

- [ ] **Step 1: Replace the smoke test with real Repository tests**

Replace `Tests/CasperGitTests/RepositoryTests.swift` with:

```swift
import XCTest
import Clibgit2
@testable import CasperGit

final class RepositoryTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("casper-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testInitializeCreatesRepository() throws {
        let repo = try Repository.initialize(atPath: tempDir.path)
        XCTAssertNotNil(repo.workdirPath)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: tempDir.appendingPathComponent(".git").path))
    }

    func testOpenExistingRepository() throws {
        _ = try Repository.initialize(atPath: tempDir.path)
        let reopened = try Repository.open(atPath: tempDir.path)
        // workdir is reported with a trailing slash by libgit2.
        XCTAssertEqual(
            URL(fileURLWithPath: reopened.workdirPath!).standardizedFileURL.path,
            tempDir.standardizedFileURL.path)
    }

    func testOpenNonRepositoryThrows() {
        XCTAssertThrowsError(try Repository.open(atPath: tempDir.path))
    }

    func testDiscoverFromSubdirectory() throws {
        _ = try Repository.initialize(atPath: tempDir.path)
        let sub = tempDir.appendingPathComponent("a/b/c")
        try FileManager.default.createDirectory(
            at: sub, withIntermediateDirectories: true)
        let repo = try Repository.discover(startingAt: sub.path)
        XCTAssertEqual(
            URL(fileURLWithPath: repo.workdirPath!).standardizedFileURL.path,
            tempDir.standardizedFileURL.path)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RepositoryTests`
Expected: FAIL to compile — `Repository` undefined.

- [ ] **Step 3: Implement Repository.swift**

`Sources/CasperGit/Repository.swift`:

```swift
import Clibgit2
import Foundation

/// A libgit2 repository handle. Owns the `git_repository*` and frees it on
/// deinit. Not `Sendable`: use from a single thread/actor.
public final class Repository {
    let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        git_repository_free(pointer)
    }

    /// Initialize a new non-bare repository at `path` (creating it if needed).
    public static func initialize(atPath path: String) throws -> Repository {
        Libgit2.ensureInit()
        var repo: OpaquePointer?
        try gitCheck(git_repository_init(&repo, path, 0))
        return Repository(pointer: repo!)
    }

    /// Open an existing repository whose git dir is exactly at `path`.
    public static func open(atPath path: String) throws -> Repository {
        Libgit2.ensureInit()
        var repo: OpaquePointer?
        try gitCheck(git_repository_open(&repo, path))
        return Repository(pointer: repo!)
    }

    /// Open the repository that owns `path`, searching upward through parents.
    public static func discover(startingAt path: String) throws -> Repository {
        Libgit2.ensureInit()
        var repo: OpaquePointer?
        // flags 0 → search parent directories; no ceiling dirs.
        try gitCheck(git_repository_open_ext(&repo, path, 0, nil))
        return Repository(pointer: repo!)
    }

    /// Absolute path to the `.git` directory (trailing slash, per libgit2).
    public var gitDirPath: String {
        String(cString: git_repository_path(pointer))
    }

    /// Absolute path to the working directory, or nil for a bare repository.
    public var workdirPath: String? {
        guard let cString = git_repository_workdir(pointer) else { return nil }
        return String(cString: cString)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter RepositoryTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CasperGit/Repository.swift Tests/CasperGitTests/RepositoryTests.swift
git commit -m "Add Repository open, discover, init, and path accessors"
```

---

## Task 4: Test fixture — repo with an initial commit

**Files:**
- Create: `Tests/CasperGitTests/GitFixture.swift`
- Test: assertions live inside `GitFixture.swift`'s own `GitFixtureTests`.

**Interfaces:**
- Consumes: `Repository`, `Clibgit2`.
- Produces: `enum GitFixture { static func repository(at:) throws ->
  Repository }` — an initialized repo with one commit on the default branch and
  a clean working tree. Used by Tasks 5–11.

- [ ] **Step 1: Write the fixture and its self-test**

`Tests/CasperGitTests/GitFixture.swift`:

```swift
import XCTest
import Clibgit2
@testable import CasperGit

/// Builds real git repositories for tests using libgit2 only (no `git` binary).
enum GitFixture {
    /// Initialize a repo at `path`, write a README, and create one commit on the
    /// repository's default branch. Returns the open `Repository`.
    @discardableResult
    static func repository(at path: String) throws -> Repository {
        let repo = try Repository.initialize(atPath: path)

        // Write a file into the working tree.
        let readme = URL(fileURLWithPath: path).appendingPathComponent("README.md")
        try "casper fixture\n".write(to: readme, atomically: true, encoding: .utf8)

        // Stage it via the index.
        var index: OpaquePointer?
        try gitCheck(git_repository_index(&index, repo.pointer))
        defer { git_index_free(index) }
        try gitCheck(git_index_add_bypath(index, "README.md"))
        try gitCheck(git_index_write(index))

        // Build the tree from the index.
        var treeOid = git_oid()
        try gitCheck(git_index_write_tree(&treeOid, index))
        var tree: OpaquePointer?
        try gitCheck(git_tree_lookup(&tree, repo.pointer, &treeOid))
        defer { git_tree_free(tree) }

        // Author/committer signature.
        var signature: UnsafeMutablePointer<git_signature>?
        try gitCheck(git_signature_now(&signature, "Casper Test", "test@casper.local"))
        defer { git_signature_free(signature) }

        // Commit onto HEAD (creates the default branch ref).
        var commitOid = git_oid()
        try gitCheck(git_commit_create_v(
            &commitOid, repo.pointer, "HEAD",
            signature, signature, nil, "Initial commit", tree, 0))

        return repo
    }
}

final class GitFixtureTests: XCTestCase {
    func testFixtureCreatesRepoWithOneCommit() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("casper-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let repo = try GitFixture.repository(at: dir.path)

        // HEAD must now resolve (born branch).
        var head: OpaquePointer?
        XCTAssertEqual(git_repository_head(&head, repo.pointer), 0)
        git_reference_free(head)
    }
}
```

- [ ] **Step 2: Run the fixture self-test**

Run: `swift test --filter GitFixtureTests`
Expected: PASS (1 test).

- [ ] **Step 3: Commit**

```bash
git add Tests/CasperGitTests/GitFixture.swift
git commit -m "Add the libgit2-only test fixture (repo with one commit)"
```

---

## Task 5: Branch queries — head, existence, checked-out

**Files:**
- Modify: `Sources/CasperGit/Repository.swift`
- Test: `Tests/CasperGitTests/RepositoryTests.swift`

**Interfaces:**
- Consumes: `Repository`, `GitFixture`.
- Produces:
  - `func Repository.headBranchName() throws -> String` — short name of the
    branch HEAD points at (throws if unborn/detached).
  - `func Repository.branchExists(_ name: String) throws -> Bool`
  - `func Repository.isBranchCheckedOut(_ name: String) throws -> Bool` — true if
    `name` is checked out in the main working tree or any worktree.

- [ ] **Step 1: Add failing tests**

Append to `RepositoryTests`:

```swift
    func testHeadBranchNameAfterFixture() throws {
        let repo = try GitFixture.repository(at: tempDir.path)
        let branch = try repo.headBranchName()
        XCTAssertFalse(branch.isEmpty)
    }

    func testBranchExists() throws {
        let repo = try GitFixture.repository(at: tempDir.path)
        let head = try repo.headBranchName()
        XCTAssertTrue(try repo.branchExists(head))
        XCTAssertFalse(try repo.branchExists("no-such-branch"))
    }

    func testHeadBranchIsCheckedOut() throws {
        let repo = try GitFixture.repository(at: tempDir.path)
        let head = try repo.headBranchName()
        XCTAssertTrue(try repo.isBranchCheckedOut(head))
        XCTAssertFalse(try repo.isBranchCheckedOut("no-such-branch"))
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter RepositoryTests`
Expected: FAIL to compile — methods undefined.

- [ ] **Step 3: Implement the branch queries**

Append to `Repository` in `Sources/CasperGit/Repository.swift`:

```swift
    /// Short name of the branch HEAD currently points to.
    public func headBranchName() throws -> String {
        var head: OpaquePointer?
        try gitCheck(git_repository_head(&head, pointer))
        defer { git_reference_free(head) }
        var shorthand: UnsafePointer<CChar>?
        shorthand = git_reference_shorthand(head)
        guard let shorthand else {
            throw GitError(code: -1, message: "HEAD has no shorthand name")
        }
        return String(cString: shorthand)
    }

    /// Whether a local branch named `name` exists.
    public func branchExists(_ name: String) throws -> Bool {
        var ref: OpaquePointer?
        let code = git_branch_lookup(&ref, pointer, name, GIT_BRANCH_LOCAL)
        defer { git_reference_free(ref) }
        if code == GIT_ENOTFOUND.rawValue { return false }
        try gitCheck(code)
        return true
    }

    /// Whether local branch `name` is checked out in any working tree. Returns
    /// false if the branch does not exist.
    public func isBranchCheckedOut(_ name: String) throws -> Bool {
        var ref: OpaquePointer?
        let code = git_branch_lookup(&ref, pointer, name, GIT_BRANCH_LOCAL)
        defer { git_reference_free(ref) }
        if code == GIT_ENOTFOUND.rawValue { return false }
        try gitCheck(code)
        return git_branch_is_checked_out(ref) == 1
    }
```

- [ ] **Step 4: Run to verify passing**

Run: `swift test --filter RepositoryTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CasperGit/Repository.swift Tests/CasperGitTests/RepositoryTests.swift
git commit -m "Add branch head, existence, and checked-out queries"
```

---

## Task 6: Worktree add

**Files:**
- Create: `Sources/CasperGit/Worktree.swift`
- Test: `Tests/CasperGitTests/WorktreeTests.swift`

**Interfaces:**
- Consumes: `Repository`, `gitCheck`, `GitFixture`.
- Produces:
  - `struct WorktreeInfo: Equatable, Sendable { let name: String; let path:
    String; let isLocked: Bool }`
  - `func Repository.addWorktree(name:atPath:basedOn:) throws -> WorktreeInfo` —
    creates a new branch named `name` (based on `basedOn`, or HEAD when nil) and
    a worktree at `atPath` checked out to it.

- [ ] **Step 1: Write the failing test**

`Tests/CasperGitTests/WorktreeTests.swift`:

```swift
import XCTest
import Clibgit2
@testable import CasperGit

final class WorktreeTests: XCTestCase {
    private var root: URL!
    private var repoDir: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("casper-wt-\(UUID().uuidString)")
        repoDir = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(
            at: repoDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testAddWorktreeCreatesBranchAndDirectory() throws {
        let repo = try GitFixture.repository(at: repoDir.path)
        let wtPath = root.appendingPathComponent("feature").path

        let info = try repo.addWorktree(
            name: "feature", atPath: wtPath, basedOn: nil)

        XCTAssertEqual(info.name, "feature")
        XCTAssertFalse(info.isLocked)
        XCTAssertTrue(FileManager.default.fileExists(atPath: wtPath))
        XCTAssertTrue(try repo.branchExists("feature"))
        XCTAssertTrue(try repo.isBranchCheckedOut("feature"))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter WorktreeTests`
Expected: FAIL to compile — `addWorktree` undefined.

- [ ] **Step 3: Implement Worktree.swift**

`Sources/CasperGit/Worktree.swift`:

```swift
import Clibgit2
import Foundation

/// Value description of a git worktree.
public struct WorktreeInfo: Equatable, Sendable {
    public let name: String
    public let path: String
    public let isLocked: Bool

    public init(name: String, path: String, isLocked: Bool) {
        self.name = name
        self.path = path
        self.isLocked = isLocked
    }
}

extension Repository {
    /// Create a worktree named `name` at `path`, checked out to a new branch
    /// (also named `name`) based on `basedOn` (a branch/tag/commit-ish) or HEAD.
    public func addWorktree(
        name: String, atPath path: String, basedOn: String?
    ) throws -> WorktreeInfo {
        // Resolve the base commit.
        var baseObject: OpaquePointer?
        if let basedOn {
            try gitCheck(git_revparse_single(&baseObject, pointer, basedOn))
        } else {
            try gitCheck(git_revparse_single(&baseObject, pointer, "HEAD"))
        }
        defer { git_object_free(baseObject) }
        var commit: OpaquePointer?
        try gitCheck(git_object_peel(&commit, baseObject, GIT_OBJECT_COMMIT))
        defer { git_object_free(commit) }

        // Create the branch at that commit.
        var branchRef: OpaquePointer?
        try gitCheck(git_branch_create(&branchRef, pointer, name, commit, 0))
        defer { git_reference_free(branchRef) }

        // Add the worktree checked out to the new branch.
        var options = git_worktree_add_options()
        git_worktree_add_options_init(
            &options, UInt32(GIT_WORKTREE_ADD_OPTIONS_VERSION))
        options.ref = branchRef

        var worktree: OpaquePointer?
        try gitCheck(git_worktree_add(&worktree, pointer, name, path, &options))
        defer { git_worktree_free(worktree) }

        return worktreeInfo(fromPointer: worktree!, name: name)
    }

    /// Build a `WorktreeInfo` from an open `git_worktree*`.
    func worktreeInfo(fromPointer worktree: OpaquePointer, name: String) -> WorktreeInfo {
        let path = String(cString: git_worktree_path(worktree))
        var reason = git_buf()
        let locked = git_worktree_is_locked(&reason, worktree) > 0
        git_buf_dispose(&reason)
        return WorktreeInfo(name: name, path: path, isLocked: locked)
    }
}
```

- [ ] **Step 4: Run to verify passing**

Run: `swift test --filter WorktreeTests`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add Sources/CasperGit/Worktree.swift Tests/CasperGitTests/WorktreeTests.swift
git commit -m "Add worktree creation on a new branch"
```

---

## Task 7: Worktree list and lookup

**Files:**
- Modify: `Sources/CasperGit/Worktree.swift`
- Test: `Tests/CasperGitTests/WorktreeTests.swift`

**Interfaces:**
- Consumes: `Repository`, `WorktreeInfo`, `gitStringArray`.
- Produces:
  - `func Repository.worktreeNames() throws -> [String]`
  - `func Repository.worktreeInfo(name:) throws -> WorktreeInfo`

- [ ] **Step 1: Add failing tests**

Append to `WorktreeTests`:

```swift
    func testListAndLookupWorktree() throws {
        let repo = try GitFixture.repository(at: repoDir.path)
        let wtPath = root.appendingPathComponent("feature").path
        _ = try repo.addWorktree(name: "feature", atPath: wtPath, basedOn: nil)

        XCTAssertEqual(try repo.worktreeNames(), ["feature"])

        let info = try repo.worktreeInfo(name: "feature")
        XCTAssertEqual(info.name, "feature")
        XCTAssertEqual(
            URL(fileURLWithPath: info.path).standardizedFileURL.path,
            URL(fileURLWithPath: wtPath).standardizedFileURL.path)
    }

    func testLookupUnknownWorktreeThrows() throws {
        let repo = try GitFixture.repository(at: repoDir.path)
        XCTAssertThrowsError(try repo.worktreeInfo(name: "ghost"))
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter WorktreeTests`
Expected: FAIL to compile — `worktreeNames` / `worktreeInfo(name:)` undefined.

- [ ] **Step 3: Implement list and lookup**

Append to the `extension Repository` in `Sources/CasperGit/Worktree.swift`:

```swift
    /// Names of all worktrees linked to this repository.
    public func worktreeNames() throws -> [String] {
        var thrown: Error?
        let names = gitStringArray { array in
            do { try gitCheck(git_worktree_list(&array, pointer)) }
            catch { thrown = error }
        }
        if let thrown { throw thrown }
        return names
    }

    /// Look up a single worktree by name.
    public func worktreeInfo(name: String) throws -> WorktreeInfo {
        var worktree: OpaquePointer?
        try gitCheck(git_worktree_lookup(&worktree, pointer, name))
        defer { git_worktree_free(worktree) }
        return worktreeInfo(fromPointer: worktree!, name: name)
    }
```

- [ ] **Step 4: Run to verify passing**

Run: `swift test --filter WorktreeTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CasperGit/Worktree.swift Tests/CasperGitTests/WorktreeTests.swift
git commit -m "Add worktree list and lookup"
```

---

## Task 8: Worktree validate and prune

**Files:**
- Modify: `Sources/CasperGit/Worktree.swift`
- Test: `Tests/CasperGitTests/WorktreeTests.swift`

**Interfaces:**
- Consumes: `Repository`, `gitCheck`.
- Produces:
  - `func Repository.isWorktreeValid(name:) throws -> Bool`
  - `func Repository.pruneWorktree(name:) throws` — validates, then prunes the
    admin entry and removes the working-tree directory.

- [ ] **Step 1: Add failing tests**

Append to `WorktreeTests`:

```swift
    func testValidateWorktree() throws {
        let repo = try GitFixture.repository(at: repoDir.path)
        let wtPath = root.appendingPathComponent("feature").path
        _ = try repo.addWorktree(name: "feature", atPath: wtPath, basedOn: nil)
        XCTAssertTrue(try repo.isWorktreeValid(name: "feature"))
    }

    func testPruneRemovesWorktree() throws {
        let repo = try GitFixture.repository(at: repoDir.path)
        let wtPath = root.appendingPathComponent("feature").path
        _ = try repo.addWorktree(name: "feature", atPath: wtPath, basedOn: nil)

        try repo.pruneWorktree(name: "feature")

        XCTAssertEqual(try repo.worktreeNames(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: wtPath))
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter WorktreeTests`
Expected: FAIL to compile — `isWorktreeValid` / `pruneWorktree` undefined.

- [ ] **Step 3: Implement validate and prune**

Append to the `extension Repository` in `Sources/CasperGit/Worktree.swift`:

```swift
    /// Whether the worktree named `name` is structurally valid (its gitdir and
    /// working directory still exist and agree).
    public func isWorktreeValid(name: String) throws -> Bool {
        var worktree: OpaquePointer?
        try gitCheck(git_worktree_lookup(&worktree, pointer, name))
        defer { git_worktree_free(worktree) }
        return git_worktree_validate(worktree) == 0
    }

    /// Prune the worktree named `name`, removing both its admin entry and its
    /// working-tree directory.
    public func pruneWorktree(name: String) throws {
        var worktree: OpaquePointer?
        try gitCheck(git_worktree_lookup(&worktree, pointer, name))
        defer { git_worktree_free(worktree) }

        var options = git_worktree_prune_options()
        git_worktree_prune_options_init(
            &options, UInt32(GIT_WORKTREE_PRUNE_OPTIONS_VERSION))
        options.flags =
            GIT_WORKTREE_PRUNE_VALID.rawValue
            | GIT_WORKTREE_PRUNE_WORKING_TREE.rawValue

        try gitCheck(git_worktree_prune(worktree, &options))
    }
```

- [ ] **Step 4: Run to verify passing**

Run: `swift test --filter WorktreeTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CasperGit/Worktree.swift Tests/CasperGitTests/WorktreeTests.swift
git commit -m "Add worktree validate and prune"
```

---

## Task 9: Repository status (clean / dirty)

**Files:**
- Modify: `Sources/CasperGit/Repository.swift`
- Test: `Tests/CasperGitTests/RepositoryTests.swift`

**Interfaces:**
- Consumes: `Repository`, `gitCheck`, `GitFixture`.
- Produces:
  - `struct FileStatus: Equatable, Sendable { let path: String; let isNew,
    isModified, isDeleted, isUntracked: Bool }`
  - `func Repository.status() throws -> [FileStatus]`
  - `func Repository.isClean() throws -> Bool`

- [ ] **Step 1: Add failing tests**

Append to `RepositoryTests`:

```swift
    func testCleanRepositoryHasNoStatusEntries() throws {
        let repo = try GitFixture.repository(at: tempDir.path)
        XCTAssertTrue(try repo.isClean())
        XCTAssertEqual(try repo.status(), [])
    }

    func testUntrackedFileMakesRepositoryDirty() throws {
        let repo = try GitFixture.repository(at: tempDir.path)
        let extra = tempDir.appendingPathComponent("scratch.txt")
        try "x".write(to: extra, atomically: true, encoding: .utf8)

        XCTAssertFalse(try repo.isClean())
        let status = try repo.status()
        XCTAssertEqual(status.count, 1)
        XCTAssertEqual(status.first?.path, "scratch.txt")
        XCTAssertTrue(status.first?.isUntracked ?? false)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter RepositoryTests`
Expected: FAIL to compile — `status` / `isClean` / `FileStatus` undefined.

- [ ] **Step 3: Implement status**

Append to `Sources/CasperGit/Repository.swift` (after the class, at file scope for
`FileStatus`; methods inside the class):

Add this value type at file scope:

```swift
/// Per-path working-tree status, reduced to the flags Casper needs.
public struct FileStatus: Equatable, Sendable {
    public let path: String
    public let isNew: Bool
    public let isModified: Bool
    public let isDeleted: Bool
    public let isUntracked: Bool

    public init(
        path: String, isNew: Bool, isModified: Bool,
        isDeleted: Bool, isUntracked: Bool
    ) {
        self.path = path
        self.isNew = isNew
        self.isModified = isModified
        self.isDeleted = isDeleted
        self.isUntracked = isUntracked
    }
}
```

Add these methods inside `final class Repository`:

```swift
    /// Working-tree status entries (index + worktree), untracked files included.
    public func status() throws -> [FileStatus] {
        var options = git_status_options()
        git_status_options_init(&options, UInt32(GIT_STATUS_OPTIONS_VERSION))
        options.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR
        options.flags =
            GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue
            | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS.rawValue

        var list: OpaquePointer?
        try gitCheck(git_status_list_new(&list, pointer, &options))
        defer { git_status_list_free(list) }

        let count = git_status_list_entrycount(list)
        var result: [FileStatus] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            guard let entry = git_status_byindex(list, index) else { continue }
            let bits = entry.pointee.status
            let delta = entry.pointee.index_to_workdir ?? entry.pointee.head_to_index
            let path: String
            if let delta, let newPath = delta.pointee.new_file.path {
                path = String(cString: newPath)
            } else {
                continue
            }
            result.append(FileStatus(
                path: path,
                isNew: bits.rawValue & GIT_STATUS_INDEX_NEW.rawValue != 0,
                isModified: bits.rawValue
                    & (GIT_STATUS_INDEX_MODIFIED.rawValue
                       | GIT_STATUS_WT_MODIFIED.rawValue) != 0,
                isDeleted: bits.rawValue
                    & (GIT_STATUS_INDEX_DELETED.rawValue
                       | GIT_STATUS_WT_DELETED.rawValue) != 0,
                isUntracked: bits.rawValue & GIT_STATUS_WT_NEW.rawValue != 0))
        }
        return result
    }

    /// Whether the working tree and index are clean (no changes, no untracked).
    public func isClean() throws -> Bool {
        try status().isEmpty
    }
```

- [ ] **Step 4: Run to verify passing**

Run: `swift test --filter RepositoryTests`
Expected: PASS (9 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CasperGit/Repository.swift Tests/CasperGitTests/RepositoryTests.swift
git commit -m "Add repository status and clean check"
```

---

## Task 10: WorktreeManager.create in CasperCore

**Files:**
- Create: `Sources/CasperCore/WorktreeManager.swift`
- Test: `Tests/CasperCoreTests/WorktreeManagerTests.swift`

**Interfaces:**
- Consumes: `CasperGit.Repository`, `WorktreeInfo`.
- Produces:
  - `struct WorktreeError: Error, Equatable` with
    `enum Reason { case repositoryNotFound, branchAlreadyCheckedOut,
    worktreePathExists, gitFailure(String) }`
  - `struct CreatedWorktree: Equatable, Sendable { let name, path, branch,
    repoPath: String }`
  - `enum WorktreeManager { static func create(repoPath:name:worktreePath:
    base:) throws -> CreatedWorktree }`

- [ ] **Step 1: Write the failing tests**

`Tests/CasperCoreTests/WorktreeManagerTests.swift`:

```swift
import Foundation
import XCTest
import CasperGit
@testable import CasperCore

final class WorktreeManagerTests: XCTestCase {
    private var root: URL!
    private var repoDir: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("casper-mgr-\(UUID().uuidString)")
        repoDir = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(
            at: repoDir, withIntermediateDirectories: true)
        try seedRepository(at: repoDir.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Seed a repo with one commit via CasperGit (mirrors the CasperGit fixture).
    private func seedRepository(at path: String) throws {
        let repo = try Repository.initialize(atPath: path)
        let readme = URL(fileURLWithPath: path).appendingPathComponent("README.md")
        try "seed\n".write(to: readme, atomically: true, encoding: .utf8)
        // Commit through a throwaway worktree add is not possible without a
        // commit, so create the initial commit with a helper branch add path:
        // reuse CasperGit by adding a first commit through its API is out of
        // scope, so shell-free seeding uses the same libgit2 calls indirectly.
        // Simplest: create the commit by adding then reading back is unavailable;
        // instead we rely on GitFixture-equivalent via CasperGit public init +
        // a first worktree requires a commit. Therefore seed the commit here.
        try makeInitialCommit(repo: repo, path: path)
    }

    func testCreateProducesWorktreeAndBranch() throws {
        let wtPath = root.appendingPathComponent("feature").path
        let created = try WorktreeManager.create(
            repoPath: repoDir.path, name: "feature",
            worktreePath: wtPath, base: nil)

        XCTAssertEqual(created.name, "feature")
        XCTAssertEqual(created.branch, "feature")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wtPath))
        XCTAssertEqual(
            URL(fileURLWithPath: created.path).standardizedFileURL.path,
            URL(fileURLWithPath: wtPath).standardizedFileURL.path)
    }

    func testCreateRejectsCheckedOutBranch() throws {
        let repo = try Repository.open(atPath: repoDir.path)
        let head = try repo.headBranchName()
        let wtPath = root.appendingPathComponent("dup").path

        XCTAssertThrowsError(
            try WorktreeManager.create(
                repoPath: repoDir.path, name: head,
                worktreePath: wtPath, base: nil)
        ) { error in
            XCTAssertEqual(
                (error as? WorktreeError)?.reason, .branchAlreadyCheckedOut)
        }
    }

    func testCreateRejectsMissingRepository() {
        XCTAssertThrowsError(
            try WorktreeManager.create(
                repoPath: root.appendingPathComponent("none").path,
                name: "x",
                worktreePath: root.appendingPathComponent("x").path, base: nil)
        ) { error in
            XCTAssertEqual(
                (error as? WorktreeError)?.reason, .repositoryNotFound)
        }
    }
}
```

> **Note for the implementer:** the `seedRepository`/`makeInitialCommit` helper
> above must create one commit through libgit2 exactly as
> `Tests/CasperGitTests/GitFixture.swift` does. Because that fixture lives in the
> `CasperGitTests` target (not importable here), **copy** its commit-creation
> body into a private `makeInitialCommit(repo:path:)` in this file, importing
> `Clibgit2`. Add `Clibgit2` to `CasperCoreTests` dependencies in `Package.swift`
> in Step 3 (`.testTarget(name: "CasperCoreTests", dependencies: ["CasperCore",
> "Clibgit2"])`). The body is the same libgit2 sequence: index add README.md →
> write tree → signature → `git_commit_create_v(..., "HEAD", ...)`.

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter WorktreeManagerTests`
Expected: FAIL to compile — `WorktreeManager`, `WorktreeError`,
`CreatedWorktree`, and the `makeInitialCommit` helper undefined.

- [ ] **Step 3: Implement WorktreeManager.create and add the helper**

Add the private `makeInitialCommit(repo:path:)` to
`WorktreeManagerTests` (copy the commit body from `GitFixture.repository`, minus
the `Repository.initialize`, operating on the passed `repo`), and update
`Package.swift`'s `CasperCoreTests` target to
`dependencies: ["CasperCore", "Clibgit2"]`.

Then create `Sources/CasperCore/WorktreeManager.swift`:

```swift
import CasperGit
import Foundation

/// A worktree-creation failure expressed in Casper's own vocabulary, so the UI
/// never sees a raw libgit2 code.
public struct WorktreeError: Error, Equatable {
    public enum Reason: Equatable {
        case repositoryNotFound
        case branchAlreadyCheckedOut
        case worktreePathExists
        case gitFailure(String)
    }

    public let reason: Reason
    public init(_ reason: Reason) { self.reason = reason }
}

/// The result of creating a worktree: enough to build a `Workspace`.
public struct CreatedWorktree: Equatable, Sendable {
    public let name: String
    public let path: String
    public let branch: String
    public let repoPath: String

    public init(name: String, path: String, branch: String, repoPath: String) {
        self.name = name
        self.path = path
        self.branch = branch
        self.repoPath = repoPath
    }
}

/// Orchestrates `CasperGit` primitives into workspace-creation operations,
/// enforcing Casper's rules and never crashing on git failure.
public enum WorktreeManager {
    /// Create a worktree named `name` (on a new branch of the same name, based
    /// on `base` or HEAD) at `worktreePath` for the repository at `repoPath`.
    public static func create(
        repoPath: String, name: String, worktreePath: String, base: String?
    ) throws -> CreatedWorktree {
        let repo: Repository
        do {
            repo = try Repository.open(atPath: repoPath)
        } catch {
            throw WorktreeError(.repositoryNotFound)
        }

        if (try? repo.isBranchCheckedOut(name)) == true {
            throw WorktreeError(.branchAlreadyCheckedOut)
        }
        if FileManager.default.fileExists(atPath: worktreePath) {
            throw WorktreeError(.worktreePathExists)
        }

        let info: WorktreeInfo
        do {
            info = try repo.addWorktree(
                name: name, atPath: worktreePath, basedOn: base)
        } catch let gitError as GitError {
            throw WorktreeError(.gitFailure(gitError.message))
        }

        return CreatedWorktree(
            name: info.name, path: info.path, branch: name,
            repoPath: repo.workdirPath ?? repoPath)
    }
}
```

- [ ] **Step 4: Run to verify passing**

Run: `swift test --filter WorktreeManagerTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CasperCore/WorktreeManager.swift \
        Tests/CasperCoreTests/WorktreeManagerTests.swift Package.swift
git commit -m "Add WorktreeManager.create with Casper-level error mapping"
```

---

## Task 11: WorktreeManager list / remove / isClean

**Files:**
- Modify: `Sources/CasperCore/WorktreeManager.swift`
- Test: `Tests/CasperCoreTests/WorktreeManagerTests.swift`

**Interfaces:**
- Consumes: `Repository`, `WorktreeInfo`.
- Produces:
  - `static func WorktreeManager.list(repoPath:) throws -> [WorktreeInfo]`
  - `static func WorktreeManager.remove(repoPath:name:) throws`
  - `static func WorktreeManager.isClean(repoPath:) throws -> Bool`

- [ ] **Step 1: Add failing tests**

Append to `WorktreeManagerTests`:

```swift
    func testListReflectsCreatedWorktrees() throws {
        let wtPath = root.appendingPathComponent("feature").path
        _ = try WorktreeManager.create(
            repoPath: repoDir.path, name: "feature",
            worktreePath: wtPath, base: nil)

        let listed = try WorktreeManager.list(repoPath: repoDir.path)
        XCTAssertEqual(listed.map(\.name), ["feature"])
    }

    func testRemoveDeletesWorktree() throws {
        let wtPath = root.appendingPathComponent("feature").path
        _ = try WorktreeManager.create(
            repoPath: repoDir.path, name: "feature",
            worktreePath: wtPath, base: nil)

        try WorktreeManager.remove(repoPath: repoDir.path, name: "feature")

        XCTAssertEqual(try WorktreeManager.list(repoPath: repoDir.path).count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wtPath))
    }

    func testIsCleanReflectsWorkingTree() throws {
        XCTAssertTrue(try WorktreeManager.isClean(repoPath: repoDir.path))
        let extra = repoDir.appendingPathComponent("dirty.txt")
        try "x".write(to: extra, atomically: true, encoding: .utf8)
        XCTAssertFalse(try WorktreeManager.isClean(repoPath: repoDir.path))
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter WorktreeManagerTests`
Expected: FAIL to compile — `list` / `remove` / `isClean` undefined.

- [ ] **Step 3: Implement the three methods**

Append to `enum WorktreeManager` in `Sources/CasperCore/WorktreeManager.swift`:

```swift
    /// List worktrees of the repository at `repoPath`.
    public static func list(repoPath: String) throws -> [WorktreeInfo] {
        let repo: Repository
        do { repo = try Repository.open(atPath: repoPath) }
        catch { throw WorktreeError(.repositoryNotFound) }

        do {
            return try repo.worktreeNames().map { try repo.worktreeInfo(name: $0) }
        } catch let gitError as GitError {
            throw WorktreeError(.gitFailure(gitError.message))
        }
    }

    /// Remove the worktree named `name` from the repository at `repoPath`.
    public static func remove(repoPath: String, name: String) throws {
        let repo: Repository
        do { repo = try Repository.open(atPath: repoPath) }
        catch { throw WorktreeError(.repositoryNotFound) }

        do { try repo.pruneWorktree(name: name) }
        catch let gitError as GitError {
            throw WorktreeError(.gitFailure(gitError.message))
        }
    }

    /// Whether the working tree of the repository at `repoPath` is clean.
    public static func isClean(repoPath: String) throws -> Bool {
        let repo: Repository
        do { repo = try Repository.open(atPath: repoPath) }
        catch { throw WorktreeError(.repositoryNotFound) }

        do { return try repo.isClean() }
        catch let gitError as GitError {
            throw WorktreeError(.gitFailure(gitError.message))
        }
    }
```

- [ ] **Step 4: Run to verify passing**

Run: `swift test --filter WorktreeManagerTests`
Expected: PASS (6 tests total in the class).

- [ ] **Step 5: Commit**

```bash
git add Sources/CasperCore/WorktreeManager.swift \
        Tests/CasperCoreTests/WorktreeManagerTests.swift
git commit -m "Add WorktreeManager list, remove, and clean check"
```

---

## Task 12: CI, Makefile, and docs for the libgit2 prerequisite

**Files:**
- Modify: `.github/workflows/ci.yml`, `Makefile`, `CLAUDE.md`

**Interfaces:**
- Produces: a green CI run that installs libgit2 + pkgconf before building, and
  developer docs noting the prerequisite.

- [ ] **Step 1: Add the Homebrew install step to CI**

In `.github/workflows/ci.yml`, insert a step **after** "Print toolchain" and
**before** "Build":

```yaml
      - name: Install libgit2
        run: brew install libgit2 pkgconf
```

- [ ] **Step 2: Document the prerequisite in the Makefile header**

In `Makefile`, extend the header comment block to read:

```make
# Casper — developer tasks
# Requires the Xcode toolchain selected (sudo xcode-select -s /Applications/Xcode.app)
# so that `swift test` can link XCTest, and libgit2 + pkgconf installed
# (brew install libgit2 pkgconf) so that CasperGit can link libgit2.
```

- [ ] **Step 3: Document the prerequisite in CLAUDE.md**

In `CLAUDE.md`, under the "Build & run" section, add a line directly under the
opening sentence:

```markdown
Requires `brew install libgit2 pkgconf` (CasperGit links libgit2 via pkg-config).
```

- [ ] **Step 4: Full build + test to confirm nothing regressed**

Run: `make all`
Expected: Plan 1's 30 tests **plus** the new CasperGit/WorktreeManager tests all
pass.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/ci.yml Makefile CLAUDE.md
git commit -m "Document and install the libgit2 build prerequisite"
```

---

## Self-Review Notes

- **Spec coverage (§8 Worktree Management):** create (`addWorktree` /
  `WorktreeManager.create`), list (`worktreeNames` / `worktreeInfo` /
  `WorktreeManager.list`), remove (`pruneWorktree` / `WorktreeManager.remove`),
  base-repo detection (`Repository.discover` / `open`), dirty/locked detection
  (`status` / `isClean`, `WorktreeInfo.isLocked`, `isWorktreeValid`), clear
  non-crashing errors (`WorktreeError`) — all covered. `git_diff` is
  intentionally deferred (documented in Goal + Global Constraints).
- **Spec coverage (§3.2 module boundaries):** `CasperGit` thin wrapper over
  libgit2, `WorktreeManager` in `CasperCore`, dependency direction
  `CasperCore → CasperGit → Clibgit2` — matches exactly. `CasperGit` never
  imports `CasperCore`.
- **Dependency policy:** libgit2 is the third allowed external; added as a
  systemLibrary (no fetched SwiftPM package); no external `git` binary anywhere.
- **Type consistency:** `Repository`, `WorktreeInfo`, `FileStatus`, `GitError`,
  `WorktreeError`, `CreatedWorktree`, and all method names are used identically
  across tasks.
- **Known deviation to watch:** Task 10 duplicates the fixture's commit-creation
  body into `CasperCoreTests` because the `CasperGitTests` fixture is not
  importable across test targets. This is intentional and documented; if a
  shared seam is wanted later, expose a minimal commit helper from `CasperGit`
  in a follow-up (out of scope here).
```

