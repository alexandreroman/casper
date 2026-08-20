# Open in Editor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a split-button to the workspace title bar's toolbar that opens
the current workspace's worktree in VS Code, IntelliJ IDEA, or Xcode.

**Architecture:** A new `EditorKind` enum + `Workspace.lastUsedEditor` field
in CasperCore (pure data, persisted in `session.json`); a new `EditorLauncher`
namespace in CasperUI (AppKit-backed detection/launch); `AppModel` wiring
(`availableEditors`, `resolvedEditor`, `openInEditor`); a `WorkspaceDetailView`
toolbar item using SwiftUI's native split-button `Menu(primaryAction:)`.

**Tech Stack:** Swift 6, SwiftUI (`Menu(primaryAction:)`, `.toolbar`), AppKit
(`NSWorkspace`, `Process`), XCTest.

## Global Constraints

- macOS 15+, arm64-only. No new external dependencies — this feature uses
  only `Foundation`/`AppKit`/`SwiftUI`.
- CasperCore stays pure Swift, no AppKit/UI imports — `EditorKind` must not
  import `AppKit`.
- Editor detection is **startup-only** (no live re-detection while the app
  runs) and must not block: three short-lived `Process` calls in `AppModel.init`.
- Detection requires **both** the CLI shim on `PATH` and the app bundle
  resolvable by bundle identifier; an editor failing either check is omitted
  entirely (not shown disabled).
- A launch failure must surface via a native alert — never silently.
- Full spec: `.superpowers/plans/open-in-editor.md`.

---

### Task 1: `EditorKind` enum in CasperCore

**Files:**
- Modify: `Sources/CasperCore/Models.swift:221-222` (insert between
  `InspectorState`'s closing brace and `public struct Workspace`)
- Test: `Tests/CasperCoreTests/ModelsTests.swift`

**Interfaces:**
- Produces: `public enum EditorKind: String, Codable, CaseIterable, Sendable { case vscode, intellijIdea, xcode }`
  with `static let priorityOrder: [EditorKind]`, `var cliCommand: String`,
  `var bundleIdentifiers: [String]`, `var displayName: String`. Task 2 stores
  this on `Workspace`; Task 3/4 read `cliCommand`/`bundleIdentifiers`/`priorityOrder`.

- [ ] **Step 1: Write the failing test**

Add to `Tests/CasperCoreTests/ModelsTests.swift` (anywhere in the file, e.g.
right after the existing `// MARK: - Inspector state` block ends, before
`testWorkspaceLegacyDecodeWithoutInspectorDefaultsIt`'s closing brace at
line 223):

```swift
    // MARK: - EditorKind

    func testEditorKindPriorityOrderIsVSCodeThenIntelliJThenXcode() {
        XCTAssertEqual(EditorKind.priorityOrder, [.vscode, .intellijIdea, .xcode])
    }

    func testEditorKindMetadataIsDistinctPerCase() {
        for kind in EditorKind.allCases {
            XCTAssertFalse(kind.cliCommand.isEmpty)
            XCTAssertFalse(kind.bundleIdentifiers.isEmpty)
            XCTAssertFalse(kind.displayName.isEmpty)
        }
        XCTAssertEqual(EditorKind.vscode.cliCommand, "code")
        XCTAssertEqual(EditorKind.intellijIdea.cliCommand, "idea")
        XCTAssertEqual(EditorKind.xcode.cliCommand, "xed")
        XCTAssertEqual(EditorKind.intellijIdea.bundleIdentifiers,
                       ["com.jetbrains.intellij", "com.jetbrains.intellij.ce"])
    }

    func testEditorKindCodableRoundTrip() throws {
        for kind in EditorKind.allCases {
            let data = try JSONEncoder().encode(kind)
            XCTAssertEqual(try JSONDecoder().decode(EditorKind.self, from: data), kind)
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ModelsTests`
Expected: FAIL — `error: cannot find type 'EditorKind' in scope` (or similar,
since `EditorKind` does not exist yet).

- [ ] **Step 3: Write minimal implementation**

Insert into `Sources/CasperCore/Models.swift` at line 222 (between
`InspectorState`'s closing `}` and `public struct Workspace`):

```swift
public enum EditorKind: String, Codable, CaseIterable, Sendable {
    case vscode
    case intellijIdea
    case xcode

    /// Priority order used both as the dropdown's display order and as the
    /// fallback when a workspace has no `lastUsedEditor` yet.
    public static let priorityOrder: [EditorKind] = [.vscode, .intellijIdea, .xcode]

    public var cliCommand: String {
        switch self {
        case .vscode: "code"
        case .intellijIdea: "idea"
        case .xcode: "xed"
        }
    }

    /// Candidate bundle identifiers, most-specific first. IntelliJ IDEA ships
    /// two distinct bundle IDs depending on edition (Ultimate vs. Community);
    /// the others have exactly one.
    public var bundleIdentifiers: [String] {
        switch self {
        case .vscode: ["com.microsoft.VSCode"]
        case .intellijIdea: ["com.jetbrains.intellij", "com.jetbrains.intellij.ce"]
        case .xcode: ["com.apple.dt.Xcode"]
        }
    }

    public var displayName: String {
        switch self {
        case .vscode: "Visual Studio Code"
        case .intellijIdea: "IntelliJ IDEA"
        case .xcode: "Xcode"
        }
    }
}

```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ModelsTests`
Expected: PASS (all `ModelsTests` tests, including the three new ones).

- [ ] **Step 5: Commit**

```bash
git add Sources/CasperCore/Models.swift Tests/CasperCoreTests/ModelsTests.swift
git commit -m "Add EditorKind enum for VS Code / IntelliJ IDEA / Xcode"
```

---

### Task 2: `Workspace.lastUsedEditor` field

**Files:**
- Modify: `Sources/CasperCore/Models.swift:223-322` (the `Workspace` struct:
  property list, `init`, `CodingKeys`, `encode(to:)`, `init(from:)`)
- Test: `Tests/CasperCoreTests/ModelsTests.swift`

**Interfaces:**
- Consumes: `EditorKind` (Task 1).
- Produces: `Workspace.lastUsedEditor: EditorKind?`, defaulting to `nil` in
  the memberwise `init` and on legacy decode. Task 4 reads/writes this field.

- [ ] **Step 1: Write the failing test**

Add to `Tests/CasperCoreTests/ModelsTests.swift`, next to
`testWorkspaceCodableRoundTripWithNonDefaultInspector` (around line 172):

```swift
    func testWorkspaceCodableRoundTripWithLastUsedEditor() throws {
        let ws = Workspace(
            name: "feat", worktreePath: "/r", branch: "feat", portBase: 40011,
            layout: .leaf(Surface(kind: .terminal(cwd: "/r"))),
            lastUsedEditor: .intellijIdea)
        let data = try JSONEncoder().encode(ws)
        let decoded = try JSONDecoder().decode(Workspace.self, from: data)
        XCTAssertEqual(decoded, ws)
        XCTAssertEqual(decoded.lastUsedEditor, .intellijIdea)
    }

    func testWorkspaceLegacyDecodeWithoutLastUsedEditorDefaultsToNil() throws {
        // A `session.json` written before this field existed has no
        // `lastUsedEditor` key; decoding it must default to nil, not throw.
        let ws = Workspace(
            name: "legacy", worktreePath: "/r", branch: "main", portBase: 40001,
            layout: .leaf(Surface(kind: .terminal(cwd: "/r"))))
        let data = try JSONEncoder().encode(ws)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "lastUsedEditor")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Workspace.self, from: legacyData)
        XCTAssertNil(decoded.lastUsedEditor)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ModelsTests`
Expected: FAIL — `error: incorrect argument label in call (have 'name:worktreePath:branch:portBase:layout:lastUsedEditor:', expected '...')`
(the `Workspace` initializer does not yet accept `lastUsedEditor:`).

- [ ] **Step 3: Write minimal implementation**

In `Sources/CasperCore/Models.swift`, modify the `Workspace` struct
(current lines 223-322):

Property list (after line 236, `public var inspector: InspectorState`):
```swift
    public var inspector: InspectorState
    public var lastUsedEditor: EditorKind?
```

`init` (lines 238-266) — add a parameter after `inspector` and assign it:
```swift
    public init(
        id: UUID = UUID(),
        name: String,
        worktreePath: String,
        branch: String,
        agentState: AgentState = .idle,
        todos: [Todo] = [],
        pendingNotification: Bool = false,
        pendingNotificationMessage: String? = nil,
        portBase: Int,
        layout: LayoutNode,
        kind: WorkspaceKind = .primary,
        baseBranch: String? = nil,
        inspector: InspectorState = InspectorState(),
        lastUsedEditor: EditorKind? = nil
    ) {
        self.id = id
        self.name = name
        self.worktreePath = worktreePath
        self.branch = branch
        self.agentState = agentState
        self.todos = todos
        self.pendingNotification = pendingNotification
        self.pendingNotificationMessage = pendingNotificationMessage
        self.portBase = portBase
        self.layout = layout
        self.kind = kind
        self.baseBranch = baseBranch
        self.inspector = inspector
        self.lastUsedEditor = lastUsedEditor
    }
```

`CodingKeys` (lines 273-277) — add `lastUsedEditor`:
```swift
    private enum CodingKeys: String, CodingKey {
        case id, name, worktreePath, branch, agentState, todos
        case pendingNotification, pendingNotificationMessage
        case portBase, layout, kind, baseBranch, inspector, lastUsedEditor
    }
```

`encode(to:)` (lines 283-296) — add after `try c.encode(inspector, forKey: .inspector)`:
```swift
        try c.encode(inspector, forKey: .inspector)
        try c.encodeIfPresent(lastUsedEditor, forKey: .lastUsedEditor)
```

`init(from:)` (lines 305-321) — add after the `inspector` decode:
```swift
        self.inspector = try container.decodeIfPresent(InspectorState.self, forKey: .inspector)
            ?? InspectorState()
        self.lastUsedEditor = try container.decodeIfPresent(EditorKind.self, forKey: .lastUsedEditor)
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ModelsTests`
Expected: PASS (all `ModelsTests` tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CasperCore/Models.swift Tests/CasperCoreTests/ModelsTests.swift
git commit -m "Persist a per-workspace last-used editor"
```

---

### Task 3: `EditorLauncher` in CasperUI

**Files:**
- Create: `Sources/CasperUI/EditorLauncher.swift`
- Test: `Tests/CasperUITests/EditorLauncherTests.swift`

**Interfaces:**
- Consumes: `EditorKind` (Task 1) — `.priorityOrder`, `.cliCommand`, `.bundleIdentifiers`.
- Produces:
  - `EditorLauncher.detectInstalled() -> [EditorKind]`
  - `EditorLauncher.icon(for: EditorKind) -> NSImage?`
  - `EditorLauncher.launch(_ kind: EditorKind, at path: String) throws`
  - `enum EditorLaunchError: LocalizedError { case shimNotFound(EditorKind) }`

  Task 4's `AppModel` calls `detectInstalled()` once in `init` and
  `launch(_:at:)` from `openInEditor`; Task 5's toolbar view calls `icon(for:)`.

- [ ] **Step 1: Write the failing test**

Create `Tests/CasperUITests/EditorLauncherTests.swift`:

```swift
import XCTest
import CasperCore
@testable import CasperUI

final class EditorLauncherTests: XCTestCase {
    /// `detectInstalled()` depends on what's actually installed on the machine
    /// running the test, so this only checks the invariant that holds
    /// regardless of environment: the result is a duplicate-free subsequence
    /// of `EditorKind.priorityOrder`, in the same relative order.
    func testDetectInstalledIsOrderedSubsequenceOfPriorityOrder() {
        let detected = EditorLauncher.detectInstalled()
        XCTAssertEqual(detected, Set(detected).sorted { l, r in
            EditorKind.priorityOrder.firstIndex(of: l)! < EditorKind.priorityOrder.firstIndex(of: r)!
        })
        for kind in detected {
            XCTAssertTrue(EditorKind.priorityOrder.contains(kind))
        }
    }

    func testLaunchThrowsShimNotFoundForAnUnresolvableCommand() {
        // Whether or not VS Code's `code` shim happens to be on this test
        // machine's PATH, launching into a directory that doesn't exist must
        // throw: either `resolveCLIPath` fails to resolve the shim
        // (`.shimNotFound`), or it resolves and `Process.run()` itself throws
        // because `currentDirectoryURL` doesn't exist. Either way, this
        // proves `launch()` propagates failure rather than swallowing it.
        XCTAssertThrowsError(try EditorLauncher.launch(.vscode, at: "/nonexistent-\(UUID().uuidString)"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter EditorLauncherTests`
Expected: FAIL — `error: cannot find 'EditorLauncher' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/CasperUI/EditorLauncher.swift`:

```swift
import AppKit
import CasperCore
import Foundation

/// Detects and launches external code editors (VS Code, IntelliJ IDEA,
/// Xcode) for a workspace's worktree. Stateless — detection is cheap enough
/// (three short-lived shell processes) to call once at app startup and cache
/// the result on `AppModel`, rather than caching inside this type.
enum EditorLauncher {
    /// Editors whose CLI shim resolves on the user's `PATH` *and* whose app
    /// bundle resolves via a known bundle identifier. Both must hold — the
    /// icon lookup needs the bundle, and the launch needs the shim — so an
    /// editor with only one of the two is omitted rather than shown
    /// half-working. Preserves `EditorKind.priorityOrder`.
    static func detectInstalled() -> [EditorKind] {
        EditorKind.priorityOrder.filter { kind in
            resolveCLIPath(kind.cliCommand) != nil && resolveBundleURL(kind) != nil
        }
    }

    static func icon(for kind: EditorKind) -> NSImage? {
        resolveBundleURL(kind).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    /// Launches `kind`'s CLI shim with `path` as its sole argument, run with
    /// `path` as the working directory. Throws on spawn failure (missing
    /// shim, permissions) so the caller can surface it.
    static func launch(_ kind: EditorKind, at path: String) throws {
        guard let cliPath = resolveCLIPath(kind.cliCommand) else {
            throw EditorLaunchError.shimNotFound(kind)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = [path]
        process.currentDirectoryURL = URL(fileURLWithPath: path)
        try process.run()
    }

    private static func resolveBundleURL(_ kind: EditorKind) -> URL? {
        kind.bundleIdentifiers.lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .first
    }

    /// Resolves `command` against the user's **login shell** `PATH`, not
    /// Casper's own process `PATH` — Casper is launched from Finder/Dock, so
    /// its environment lacks shell-profile `PATH` additions (Homebrew, `nvm`,
    /// JetBrains Toolbox shims, etc.) where `code`/`idea`/`xed` commonly live.
    /// Runs `$SHELL -lc 'which <command>'`, discarding stderr, and trims the
    /// captured stdout; `nil` on a non-zero exit or empty output.
    private static func resolveCLIPath(_ command: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "which \(command)"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        } catch {
            return nil
        }
    }
}

enum EditorLaunchError: LocalizedError {
    case shimNotFound(EditorKind)

    var errorDescription: String? {
        switch self {
        case .shimNotFound(let kind):
            "\(kind.displayName)'s `\(kind.cliCommand)` command is no longer on your PATH."
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter EditorLauncherTests`
Expected: PASS. (`testLaunchThrowsShimNotFoundForAnUnresolvableCommand` passes
whether or not VS Code is installed: if the shim isn't found, `launch` throws
`.shimNotFound` directly; if it is found, `Process.run()` throws because the
working directory doesn't exist — either way it's a thrown error.)

- [ ] **Step 5: Commit**

```bash
git add Sources/CasperUI/EditorLauncher.swift Tests/CasperUITests/EditorLauncherTests.swift
git commit -m "Add EditorLauncher: detect and launch VS Code / IntelliJ IDEA / Xcode"
```

---

### Task 4: `AppModel` wiring

**Files:**
- Modify: `Sources/CasperUI/AppModel.swift:17-40` (stored properties),
  `Sources/CasperUI/AppModel.swift:270` (init, after `resolveGitBacking()`),
  `Sources/CasperUI/AppModel.swift:993-997` (new methods, next to
  `setInspectorCollapsed`)
- Test: `Tests/CasperUITests/AppModelTests.swift`

**Interfaces:**
- Consumes: `EditorKind` (Task 1), `Workspace.lastUsedEditor` (Task 2),
  `EditorLauncher.detectInstalled()`/`.launch(_:at:)` (Task 3), `locate(_:)`,
  `persist()`, `onPersistForTest` (existing `AppModel` internals).
- Produces:
  - `AppModel.availableEditors: [EditorKind]` (read-only, set once in `init`)
  - `AppModel.editorLaunchError: String?` (read-write, drives Task 5's `.alert`)
  - `AppModel.resolvedEditor(_ kind: EditorKind?, for workspace: Workspace) -> EditorKind?`
  - `AppModel.openInEditor(_ kind: EditorKind?, for workspaceID: UUID)`

  Task 5's `WorkspaceDetailView` calls `model.availableEditors`,
  `model.openInEditor(_:for:)`, and binds an alert to `model.editorLaunchError`.

- [ ] **Step 1: Write the failing test**

Add to `Tests/CasperUITests/AppModelTests.swift`, in a new `// MARK: - Open in
Editor` section (e.g. right after the `// MARK: - Right inspector panel`
block ends, after line 951):

```swift
    // MARK: - Open in Editor

    func testResolvedEditorPrefersExplicitKindOverWorkspaceOverAvailable() {
        let (model, _) = modelWithOnePlainWorkspace()
        var workspace = model.spaces[0].workspaces[0]
        workspace.lastUsedEditor = .intellijIdea
        XCTAssertEqual(model.resolvedEditor(.xcode, for: workspace), .xcode)
    }

    func testResolvedEditorFallsBackToWorkspaceLastUsedEditor() {
        let (model, _) = modelWithOnePlainWorkspace()
        var workspace = model.spaces[0].workspaces[0]
        workspace.lastUsedEditor = .intellijIdea
        XCTAssertEqual(model.resolvedEditor(nil, for: workspace), .intellijIdea)
    }

    func testResolvedEditorFallsBackToFirstAvailableEditor() {
        let (model, _) = modelWithOnePlainWorkspace()
        let workspace = model.spaces[0].workspaces[0]
        XCTAssertNil(workspace.lastUsedEditor)
        XCTAssertEqual(model.resolvedEditor(nil, for: workspace), model.availableEditors.first)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AppModelTests`
Expected: FAIL — `error: value of type 'AppModel' has no member 'resolvedEditor'`
(and no member `availableEditors`).

- [ ] **Step 3: Write minimal implementation**

In `Sources/CasperUI/AppModel.swift`, add two stored properties near the top
(after `private(set) var diffRevision = 0` and its doc comment, around
line 23):

```swift
    private(set) var diffRevision = 0

    /// Editors detected as launchable at startup (CLI shim on `PATH` and app
    /// bundle resolvable), in `EditorKind.priorityOrder`. Never re-detected
    /// while the app is running.
    private(set) var availableEditors: [EditorKind] = []

    /// Set when `openInEditor` fails to launch; drives a `.alert` in
    /// `WorkspaceDetailView`. Not part of any persisted model.
    var editorLaunchError: String?
```

In `init` (`AppModel.swift`, after `resolveGitBacking()` at line 270):

```swift
        resolveGitBacking()
        self.availableEditors = EditorLauncher.detectInstalled()
        reconfigureWorktreeWatcher()
```

Next to `setInspectorCollapsed` (after line 997's closing `}`):

```swift
    /// Resolves which editor a click should launch: an explicit `kind` (from
    /// picking a dropdown row) wins, else the workspace's remembered default,
    /// else the first detected editor. Pure and side-effect-free so it is
    /// unit-testable without touching `EditorLauncher`/`Process`.
    func resolvedEditor(_ kind: EditorKind?, for workspace: Workspace) -> EditorKind? {
        kind ?? workspace.lastUsedEditor ?? availableEditors.first
    }

    /// Launches `kind` (or the workspace's remembered/default editor when
    /// nil) on the workspace's worktree, and remembers it as this
    /// workspace's default for next time.
    func openInEditor(_ kind: EditorKind?, for workspaceID: UUID) {
        guard let at = locate(workspaceID) else { return }
        let workspace = spaces[at.space].workspaces[at.workspace]
        guard let resolved = resolvedEditor(kind, for: workspace) else { return }
        do {
            try EditorLauncher.launch(resolved, at: workspace.worktreePath)
            spaces[at.space].workspaces[at.workspace].lastUsedEditor = resolved
            persist()
        } catch {
            editorLaunchError = error.localizedDescription
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AppModelTests`
Expected: PASS (all `AppModelTests` tests, including the three new ones).

- [ ] **Step 5: Commit**

```bash
git add Sources/CasperUI/AppModel.swift Tests/CasperUITests/AppModelTests.swift
git commit -m "Wire AppModel.openInEditor and per-workspace editor resolution"
```

---

### Task 5: Toolbar split-button in `WorkspaceDetailView`

**Files:**
- Modify: `Sources/CasperUI/WorkspaceDetailView.swift:76-90` (toolbar),
  `Sources/CasperUI/WorkspaceDetailView.swift:203-212` (new `editorButton`
  computed property, next to `inspectorToggle`)

**Interfaces:**
- Consumes: `model.availableEditors`, `model.openInEditor(_:for:)`,
  `model.editorLaunchError` (Task 4); `EditorLauncher.icon(for:)` (Task 3);
  `workspace.lastUsedEditor` (Task 2); `EditorKind.displayName` (Task 1).
- Produces: no new public interface — this is the leaf UI consumer.

This task has no automated test: it is a SwiftUI toolbar view, and the
project's existing testing strategy covers this layer manually via the
`debug-casper` harness and a live GUI pass, not XCTest (see
`.superpowers/architecture.md` → Testing strategy; no existing test in this
repo drives a `.toolbar` view). Steps 1-2 below are the manual-verification
equivalent of "write the test, watch it fail" — confirm the button is
genuinely absent before wiring it in.

- [ ] **Step 1: Confirm the toolbar has no editor button yet**

Run: `make dev`
In the running app, open any workspace and look at the title bar's trailing
group (next to the panel-toggle icon). Expected: no editor button is present
— only the diff badge (if the workspace has uncommitted changes) and the
panel toggle (`sidebar.right` icon).

- [ ] **Step 2: Quit the app**

Quit Casper (`⌘Q`) before editing its source, since `make dev` rebuilds and
relaunches.

- [ ] **Step 3: Implement the toolbar item and split-button**

In `Sources/CasperUI/WorkspaceDetailView.swift`, modify the `.toolbar` block
(current lines 76-90):

```swift
        .toolbar {
            ToolbarItem(placement: .navigation) { title }
            ToolbarItem(placement: .navigation) { diffBadge }.flatToolbarItem()
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.flexible)
            }
            if !model.availableEditors.isEmpty {
                ToolbarItem(placement: .primaryAction) { editorButton }
            }
            // Expanded: strip the glass so the toggle doesn't merge into the diff
            // badge's capsule (a macOS 26 glass-merge artifact). Collapsed: keep it.
            let inspectorItem = ToolbarItem(placement: .primaryAction) { inspectorToggle }
            if workspace.inspector.collapsed {
                inspectorItem
            } else {
                inspectorItem.flatToolbarItem()
            }
        }
```

Add a `.alert` right after the closing `.toolbar { ... }` block (before
`.task(id: model.selectedWorkspaceID)` at current line 91):

```swift
        .alert("Couldn't Open Editor", isPresented: Binding(
            get: { model.editorLaunchError != nil },
            set: { if !$0 { model.editorLaunchError = nil } }
        )) {
            Button("OK") { model.editorLaunchError = nil }
        } message: {
            Text(model.editorLaunchError ?? "")
        }
```

Add `editorButton` next to `inspectorToggle` (current lines 203-210):

```swift
    private var editorButton: some View {
        let current = workspace.lastUsedEditor ?? model.availableEditors.first
        return Menu {
            ForEach(model.availableEditors, id: \.self) { kind in
                Button {
                    model.openInEditor(kind, for: workspace.id)
                } label: {
                    editorLabel(kind)
                }
            }
        } label: {
            if let current {
                editorLabel(current)
            } else {
                Text("Editor")
            }
        } primaryAction: {
            model.openInEditor(nil, for: workspace.id)
        }
        .help("Open in Editor")
    }

    @ViewBuilder
    private func editorLabel(_ kind: EditorKind) -> some View {
        if let icon = EditorLauncher.icon(for: kind) {
            Label { Text(kind.displayName) } icon: { Image(nsImage: icon) }
        } else {
            Text(kind.displayName)
        }
    }
```

- [ ] **Step 4: Build**

Run: `make build`
Expected: builds with no errors or warnings.

- [ ] **Step 5: Manual verification with `make dev`**

Run: `make dev`. For each check below, note which are only possible with a
real editor CLI shim installed (`code`/`idea`/`xed` on `PATH`) — skip
checks for editors not installed on this machine, but run at least one:

- Open a workspace. If at least one of VS Code / IntelliJ IDEA / Xcode is
  detected, the new button appears immediately left of the panel-toggle
  icon, showing that editor's real name + icon (first by
  `EditorKind.priorityOrder` on a workspace never opened before).
- Click the main part of the button (not the chevron): the editor launches
  on the workspace's worktree path.
- Click the chevron: a dropdown lists only the detected editors. Pick a
  different one — it launches, and the button's label updates to that
  editor.
- Quit and relaunch Casper (`make dev` again), reselect the same workspace:
  the button still shows the last editor you picked (persisted).
- If zero editors are detected on this machine, confirm the button is
  absent entirely (no empty/disabled control in its place).

- [ ] **Step 6: Commit**

```bash
git add Sources/CasperUI/WorkspaceDetailView.swift
git commit -m "Add Open in Editor split-button to the workspace toolbar"
```
