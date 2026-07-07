# Close Inspector (`browser close` / `diff close`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan
> task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `casper browser close` and `casper diff close` CLI subcommands
that collapse the shared inspector panel when their view is the active tab.

**Architecture:** Two new `ControlCommand.Verb` cases (`browserClose`,
`diffClose`) carry no new payload — just the existing `workspace` selector.
`ControlServer.handle(_:)` routes them to two new `AppModel` methods
(`controlCloseBrowser`, `controlCloseDiff`) that collapse `InspectorState`
only when its `tab` matches, and no-op (success) otherwise. Two new `Close`
subcommands on `BrowserCommand`/`DiffCommand`, shaped exactly like
`TerminalCommand.Close`, send the command and print `WorkspaceRefOut`.

**Tech Stack:** Swift 6, ArgumentParser, XCTest.

## Global Constraints

- Design source of truth: `.superpowers/plans/close-inspector.md` (approved).
- `--workspace` reuses the existing `WorkspaceTargetOption` / `requireSelector`
  — no new flag semantics.
- Both new CLI commands send with `retriable: false`, matching every other
  mutating command (`browserOpen`, `diffOpen`, `terminalClose`).
- No new output struct — reuse `WorkspaceRefOut` (`JSONOutput.swift:52-54`).
- Closing never clears `inspector.browser`'s `Surface` or `diffScrollTarget` —
  only `InspectorState.collapsed` changes.

---

### Task 1: `ControlCommand.Verb` cases + `AppModel` close handlers

**Files:**
- Modify: `Sources/CasperCore/ControlProtocol.swift:6-19` (add two `Verb` cases)
- Modify: `Sources/CasperUI/AppModel.swift:1328-1368` (add two methods, right
  after `controlOpenDiff`)
- Test: `Tests/CasperUITests/ControlHandlerTests.swift`

**Interfaces:**
- Consumes: `InspectorState` (`Sources/CasperCore/Models.swift:154-176`,
  fields `collapsed: Bool`, `tab: InspectorTab`), `InspectorTab` (`.browser`/`.diff`,
  `Models.swift:145-147`), `AppModel.workspace(id:) -> Workspace?`
  (`AppModel.swift:272`), `AppModel.setInspectorCollapsed(_:for:)`
  (`AppModel.swift:928-932`).
- Produces: `ControlCommand.Verb.browserClose`, `ControlCommand.Verb.diffClose`;
  `AppModel.controlCloseBrowser(in workspaceID: UUID) -> Bool`,
  `AppModel.controlCloseDiff(in workspaceID: UUID) -> Bool` — both return
  `false` only when the workspace can't be located, `true` otherwise (whether
  or not the tab matched).

- [ ] **Step 1: Write the failing AppModel tests**

Add to `Tests/CasperUITests/ControlHandlerTests.swift`, right after
`testOpenBrowserLoadsInspectorBrowserAndSelectsTab` (after line 166):

```swift
func testCloseBrowserCollapsesWhenBrowserTabActive() throws {
    let (model, id) = seededModel()
    let url = URL(string: "https://example.com")!
    XCTAssertTrue(model.controlOpenBrowser(url: url, in: id))
    XCTAssertFalse(try XCTUnwrap(model.workspace(id: id)).inspector.collapsed)

    XCTAssertTrue(model.controlCloseBrowser(in: id))
    XCTAssertTrue(try XCTUnwrap(model.workspace(id: id)).inspector.collapsed)
}

func testCloseBrowserNoOpsWhenDiffTabActive() throws {
    let (model, id, _) = try seededGitModel(primaryBranch: "main")
    guard case .success = model.controlOpenDiff(in: id) else {
        return XCTFail("expected success")
    }
    XCTAssertFalse(try XCTUnwrap(model.workspace(id: id)).inspector.collapsed)

    XCTAssertTrue(model.controlCloseBrowser(in: id))  // still succeeds
    let ws = try XCTUnwrap(model.workspace(id: id))
    XCTAssertEqual(ws.inspector.tab, .diff)   // untouched
    XCTAssertFalse(ws.inspector.collapsed)    // untouched — diff still showing
}

func testCloseBrowserFailsForUnknownWorkspace() {
    let (model, _) = seededModel()
    XCTAssertFalse(model.controlCloseBrowser(in: UUID()))
}

func testCloseDiffCollapsesWhenDiffTabActive() throws {
    let (model, id, _) = try seededGitModel(primaryBranch: "main")
    guard case .success = model.controlOpenDiff(in: id) else {
        return XCTFail("expected success")
    }
    XCTAssertFalse(try XCTUnwrap(model.workspace(id: id)).inspector.collapsed)

    XCTAssertTrue(model.controlCloseDiff(in: id))
    XCTAssertTrue(try XCTUnwrap(model.workspace(id: id)).inspector.collapsed)
}

func testCloseDiffNoOpsWhenBrowserTabActive() throws {
    let (model, id) = seededModel()
    let url = URL(string: "https://example.com")!
    XCTAssertTrue(model.controlOpenBrowser(url: url, in: id))
    XCTAssertFalse(try XCTUnwrap(model.workspace(id: id)).inspector.collapsed)

    XCTAssertTrue(model.controlCloseDiff(in: id))  // still succeeds
    let ws = try XCTUnwrap(model.workspace(id: id))
    XCTAssertEqual(ws.inspector.tab, .browser)  // untouched
    XCTAssertFalse(ws.inspector.collapsed)      // untouched — browser still showing
}

func testCloseDiffFailsForUnknownWorkspace() {
    let (model, _) = seededModel()
    XCTAssertFalse(model.controlCloseDiff(in: UUID()))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ControlHandlerTests 2>&1 | tail -40`
Expected: build FAILS — `controlCloseBrowser`/`controlCloseDiff` do not exist yet.

- [ ] **Step 3: Add the `Verb` cases**

In `Sources/CasperCore/ControlProtocol.swift`, change lines 14-15 from:

```swift
        case browserOpen
        case diffOpen
```

to:

```swift
        case browserOpen
        case browserClose
        case diffOpen
        case diffClose
```

- [ ] **Step 4: Implement the `AppModel` handlers**

In `Sources/CasperUI/AppModel.swift`, insert immediately after
`controlOpenDiff`'s closing brace (after line 1368):

```swift
    /// Collapse the inspector if `workspaceID`'s active tab is `.browser`.
    /// No-op (still succeeds) if the diff tab is active or the panel is
    /// already collapsed — the caller's goal ("browser not showing") already
    /// holds either way.
    @discardableResult
    func controlCloseBrowser(in workspaceID: UUID) -> Bool {
        guard let ws = workspace(id: workspaceID) else { return false }
        if ws.inspector.tab == .browser {
            setInspectorCollapsed(true, for: workspaceID)
        }
        return true
    }

    /// Collapse the inspector if `workspaceID`'s active tab is `.diff`.
    /// Mirrors `controlCloseBrowser`.
    @discardableResult
    func controlCloseDiff(in workspaceID: UUID) -> Bool {
        guard let ws = workspace(id: workspaceID) else { return false }
        if ws.inspector.tab == .diff {
            setInspectorCollapsed(true, for: workspaceID)
        }
        return true
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter ControlHandlerTests 2>&1 | tail -40`
Expected: PASS, including the 6 new tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/CasperCore/ControlProtocol.swift Sources/CasperUI/AppModel.swift \
        Tests/CasperUITests/ControlHandlerTests.swift
git commit -m "Add browserClose/diffClose control verbs and AppModel handlers"
```

---

### Task 2: `ControlServer` dispatch

**Files:**
- Modify: `Sources/CasperUI/ControlServer.swift:80-90`
- Test: `Tests/CasperUITests/ControlServerTests.swift`

**Interfaces:**
- Consumes: `ControlCommand.Verb.browserClose`/`.diffClose` (Task 1),
  `AppModel.controlCloseBrowser(in:)`/`controlCloseDiff(in:)` (Task 1),
  `ControlResponse.success(workspace:)`/`.failure(_:)` (`ControlProtocol.swift:112-123`).
- Produces: `ControlServer.handle(_:)` now routes `.browserClose`/`.diffClose`.

- [ ] **Step 1: Write the failing dispatch tests**

Add to `Tests/CasperUITests/ControlServerTests.swift`, right after
`testWorkspaceListDispatch` (after line 63, before the closing `}`):

```swift
    func testBrowserCloseDispatch() throws {
        let (server, id) = try seededServer()
        let response = server.handle(
            ControlCommand(verb: .browserClose, workspace: id.uuidString))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.workspace, id.uuidString)
    }

    func testDiffCloseDispatch() throws {
        let (server, id) = try seededServer()
        let response = server.handle(
            ControlCommand(verb: .diffClose, workspace: id.uuidString))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.workspace, id.uuidString)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ControlServerTests 2>&1 | tail -40`
Expected: build FAILS — the `switch` in `handle(_:)` is not yet exhaustive for
the new `Verb` cases (Swift's `Verb` switches have no `default`, so this is a
compile error, not a runtime failure).

- [ ] **Step 3: Add the dispatch cases**

In `Sources/CasperUI/ControlServer.swift`, change lines 80-85 from:

```swift
        case .browserOpen:
            guard let raw = command.url, let url = URL(string: raw), url.scheme != nil, url.host != nil else {
                return .failure("invalid url: \(command.url ?? "nil")")
            }
            return model.controlOpenBrowser(url: url, in: id)
                ? .success(workspace: id.uuidString) : .failure("cannot open browser")
        case .diffOpen:
```

to:

```swift
        case .browserOpen:
            guard let raw = command.url, let url = URL(string: raw), url.scheme != nil, url.host != nil else {
                return .failure("invalid url: \(command.url ?? "nil")")
            }
            return model.controlOpenBrowser(url: url, in: id)
                ? .success(workspace: id.uuidString) : .failure("cannot open browser")
        case .browserClose:
            return model.controlCloseBrowser(in: id)
                ? .success(workspace: id.uuidString) : .failure("cannot close browser")
        case .diffClose:
            return model.controlCloseDiff(in: id)
                ? .success(workspace: id.uuidString) : .failure("cannot close diff")
        case .diffOpen:
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ControlServerTests 2>&1 | tail -40`
Expected: PASS, including the 2 new tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/CasperUI/ControlServer.swift Tests/CasperUITests/ControlServerTests.swift
git commit -m "Dispatch browserClose/diffClose control commands in ControlServer"
```

---

### Task 3: CLI subcommands (`browser close`, `diff close`)

**Files:**
- Modify: `Sources/CasperCLI/BrowserCommand.swift`
- Modify: `Sources/CasperCLI/DiffCommand.swift`
- Test: `Tests/CasperCLITests/ControlCommandTests.swift`

**Interfaces:**
- Consumes: `ControlCommand.Verb.browserClose`/`.diffClose` (Task 1),
  `WorkspaceTargetOption` + `requireSelector` (`ControlClient.swift:7-24`),
  `sendControl` (`ControlClient.swift:30`), `WorkspaceRefOut`
  (`JSONOutput.swift:52-54`), `emit` (CLI output helper already used by
  `BrowserCommand.Open`/`DiffCommand.Open`).
- Produces: `casper browser close [--workspace <id>]`,
  `casper diff close [--workspace <id>]` — both parseable `ParsableCommand`
  types registered as subcommands of `BrowserCommand`/`DiffCommand`.

- [ ] **Step 1: Write the failing CLI parsing tests**

Add to `Tests/CasperCLITests/ControlCommandTests.swift`, right after
`testBrowserOpenRejectsInvalidURL` (after line 102, before `testDiffOpenBuildsCommand`):

```swift
    func testBrowserCloseBuildsCommand() throws {
        let close = try BrowserCommand.Close.parse(["--workspace", "feature"])
        let command = try close.makeCommand()
        XCTAssertEqual(command.verb, .browserClose)
        XCTAssertEqual(command.workspace, "feature")
    }

```

Add to the same file, right after `testDiffOpenCarriesFileArgument` (after
line 116, before `testWorkspaceNewBuildsCommand`):

```swift
    func testDiffCloseBuildsCommand() throws {
        let close = try DiffCommand.Close.parse(["--workspace", "feature"])
        let command = try close.makeCommand()
        XCTAssertEqual(command.verb, .diffClose)
        XCTAssertEqual(command.workspace, "feature")
    }

```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ControlCommandTests 2>&1 | tail -40`
Expected: build FAILS — `BrowserCommand.Close`/`DiffCommand.Close` do not
exist yet.

- [ ] **Step 3: Add `BrowserCommand.Close`**

In `Sources/CasperCLI/BrowserCommand.swift`, change the whole file to:

```swift
import ArgumentParser
import CasperCore
import Foundation

/// `casper browser open <url>` / `casper browser close` — open a URL in, or
/// collapse, the workspace's browser panel.
struct BrowserCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "browser",
        abstract: "Open or close a workspace's browser panel.",
        subcommands: [Open.self, Close.self])

    struct Open: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Open a URL in the browser panel.")

        @Argument(help: "URL to open.")
        var url: String
        @OptionGroup var target: WorkspaceTargetOption

        func makeCommand() throws -> ControlCommand {
            guard !url.isEmpty else { throw exitWithError("missing url") }
            guard let parsed = URL(string: url), parsed.scheme != nil, parsed.host != nil else {
                throw exitWithError("invalid url '\(url)' (expected an absolute URL like https://example.com)")
            }
            let selector = try requireSelector(target)
            return ControlCommand(verb: .browserOpen, workspace: selector, url: url)
        }

        func run() throws {
            let response = try sendControl(makeCommand(), retriable: false)
            emit(WorkspaceRefOut(workspace: response.workspace ?? ""))
        }
    }

    struct Close: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Collapse the inspector if the browser panel is showing.")

        @OptionGroup var target: WorkspaceTargetOption

        func makeCommand() throws -> ControlCommand {
            ControlCommand(verb: .browserClose, workspace: try requireSelector(target))
        }

        func run() throws {
            let response = try sendControl(makeCommand(), retriable: false)
            emit(WorkspaceRefOut(workspace: response.workspace ?? ""))
        }
    }
}
```

- [ ] **Step 4: Add `DiffCommand.Close`**

In `Sources/CasperCLI/DiffCommand.swift`, change the whole file to:

```swift
import ArgumentParser
import CasperCore

/// `casper diff open [<file>]` / `casper diff close` — open, or collapse, the
/// diff view of a workspace.
struct DiffCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diff",
        abstract: "Open or close the diff view of a workspace.",
        subcommands: [Open.self, Close.self])

    struct Open: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Open the diff view.")

        @Argument(help: "File path to scroll the diff view to (optional).")
        var file: String?
        @OptionGroup var workspaceTarget: WorkspaceTargetOption

        func makeCommand() throws -> ControlCommand {
            ControlCommand(
                verb: .diffOpen, workspace: try requireSelector(workspaceTarget), target: file)
        }

        func run() throws {
            let response = try sendControl(makeCommand(), retriable: false)
            emit(WorkspaceRefOut(workspace: response.workspace ?? ""))
        }
    }

    struct Close: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Collapse the inspector if the diff view is showing.")

        @OptionGroup var workspaceTarget: WorkspaceTargetOption

        func makeCommand() throws -> ControlCommand {
            ControlCommand(verb: .diffClose, workspace: try requireSelector(workspaceTarget))
        }

        func run() throws {
            let response = try sendControl(makeCommand(), retriable: false)
            emit(WorkspaceRefOut(workspace: response.workspace ?? ""))
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter ControlCommandTests 2>&1 | tail -40`
Expected: PASS, including the 2 new tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/CasperCLI/BrowserCommand.swift Sources/CasperCLI/DiffCommand.swift \
        Tests/CasperCLITests/ControlCommandTests.swift
git commit -m "Add casper browser close / diff close CLI subcommands"
```

---

### Task 4: Full-suite verification + manual check

**Files:** none (verification only)

- [ ] **Step 1: Run the full test suite**

Run: `make test 2>&1 | tail -60`
Expected: PASS, no regressions.

- [ ] **Step 2: Manual verification via `make dev`**

Run: `make dev`, then in a terminal inside a Casper workspace:

```bash
casper browser open https://example.com   # inspector expands, browser tab active
casper browser close                      # inspector collapses
casper diff open                          # inspector expands, diff tab active
casper browser close                      # no-op: inspector stays expanded on diff tab
casper diff close                         # inspector collapses
```

Expected: inspector visibly expands/collapses only when the matching command
targets the currently-active tab; the other close command is a silent no-op
(exits 0, no visible change).

- [ ] **Step 3: Commit** (only if step 2 uncovered fixes; otherwise skip)
