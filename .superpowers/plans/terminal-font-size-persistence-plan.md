# Per-Terminal Font Size Persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan
> task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Each terminal surface remembers its own live font size (as adjusted
via Cmd+/Cmd-/Cmd0) and restores it on the next launch, independent of every
other terminal.

**Architecture:** `Surface` (`CasperCore/Models.swift`) gains a flat
`fontSize: Float?` field. `GhosttySurface` (`CasperGhostty`) gains
`currentFontSize()`, reading libghostty's `ghostty_surface_inherited_config`
— the same mechanism libghostty uses to propagate a runtime-adjusted font
size to a new child split. `GhosttySurfaceView`'s three font-size actions
read this back immediately after forwarding to libghostty and report changes
through a new `onFontSizeChange` closure. `AppModel` wires that closure, at
the single `surfaceView(for:in:)` chokepoint, to a new `updateSurfaceFontSize`
method that finds the `Surface` in its workspace's `LayoutNode` tree (via a
new `LayoutTree.updateSurface` pure mutator), sets `.fontSize`, and calls the
existing debounced `scheduleSave()`. Restore falls out of one change: the
same `surfaceConfiguration(for:terminal:)` that creates fresh terminals also
recreates restored ones, so passing `terminal.fontSize ?? 0` there covers
both.

**Tech Stack:** Swift 6, GhosttyKit (libghostty), XCTest.

## Global Constraints

- Design source of truth: `.superpowers/plans/terminal-font-size-persistence.md`
  (approved).
- `Surface.fontSize: Float?` is a flat field on `Surface` (not inside `Kind`'s
  associated values), matching the hand-rolled-`Codable`-for-migration
  pattern already used for `InspectorState.width`, `Workspace.inspector`, and
  `Space.isCollapsed` in `Models.swift`.
- `nil` means "not customized — use libghostty's own default." Only
  meaningful for `.terminal` surfaces; ignored for `.browser`.
- No new save-trigger mechanism: reuse the existing debounced `scheduleSave()`
  (same mechanism already used for inspector-width drag persistence). No
  periodic/idle autosave.
- No new global/default font-size preference (no `AppStorage`/`UserDefaults`).
- `persist()` itself needs no change: it already serializes `spaces`
  wholesale, so the mutated `fontSize` rides along automatically.
- The design's Risk/Spike section calls for a *manual* spike (adjust font
  size via Cmd+ in the running app, log the value, eyeball it). Task 1 below
  implements the equivalent as an automated XCTest instead: it exercises the
  exact same libghostty call through a real (offscreen) window and a real
  live surface — the established pattern in
  `Tests/CasperGhosttyTests/GhosttyEditingCommandReplayTests.swift` — and
  asserts on the result rather than requiring a human to read a log line.
  This is strictly more repeatable and becomes permanent regression coverage.
  **If Task 1's assertion fails, stop and revisit the design's Alternatives
  section before doing any further task in this plan.**

---

### Task 1: Spike — confirm `ghostty_surface_inherited_config` reflects live font-size changes

**Files:**
- Modify: `Sources/CasperGhostty/GhosttySurface.swift:141-152` (add
  `currentFontSize()` after `geometry()`, before the closing brace)
- Create: `Tests/CasperGhosttyTests/GhosttyFontSizeTests.swift`

**Interfaces:**
- Consumes: `ghostty_surface_inherited_config(ghostty_surface_t,
  ghostty_surface_context_e) -> ghostty_surface_config_s` (`ghostty.h:1095`),
  `GHOSTTY_SURFACE_CONTEXT_WINDOW` (`ghostty.h:435`),
  `ghostty_surface_config_s.font_size: Float` (`ghostty.h:461`),
  `GhosttySurface.bindingAction(_:) -> Bool` (`GhosttySurface.swift:104-109`),
  `GhosttyRuntime()` throwing init (real app/surface, used by
  `GhosttyEditingCommandReplayTests`), `GhosttySurfaceView.surface:
  GhosttySurface?` (internal, visible via `@testable import`).
- Produces: `GhosttySurface.currentFontSize() -> Float` — used by Task 4's
  `reportFontSizeIfChanged()`.

- [ ] **Step 1: Write the failing test**

Create `Tests/CasperGhosttyTests/GhosttyFontSizeTests.swift`:

```swift
import AppKit
import GhosttyKit
import XCTest

@testable import CasperGhostty

/// Spike (see `.superpowers/plans/terminal-font-size-persistence.md`,
/// Risk/Spike): confirms `ghostty_surface_inherited_config` reflects a LIVE,
/// runtime-adjusted font size — its documented purpose is building a config
/// for a *new child* split, and whether it also echoes the current surface's
/// own live size was unconfirmed before this test. Uses a real runtime + a
/// real (offscreen) window, exactly like `GhosttyEditingCommandReplayTests`
/// — the `.forTesting()` runtime never creates a surface.
final class GhosttyFontSizeTests: XCTestCase {
    @MainActor
    func testInheritedConfigReflectsLiveFontSizeIncrease() throws {
        let runtime = try GhosttyRuntime()
        let view = GhosttySurfaceView(runtime: runtime, configuration: GhosttySurfaceConfiguration())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view  // triggers viewDidMoveToWindow -> ghostty_surface_new

        // Surface creation can transiently return null and retry; poll until it
        // lands, matching GhosttyEditingCommandReplayTests's precondition guard.
        let deadline = Date().addingTimeInterval(10)
        while view.surface == nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        guard let surface = view.surface else {
            throw XCTSkip("libghostty could not create a surface in this environment")
        }

        let before = surface.currentFontSize()
        surface.bindingAction("increase_font_size:1")
        surface.bindingAction("increase_font_size:1")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let after = surface.currentFontSize()

        XCTAssertGreaterThan(
            after, before,
            "ghostty_surface_inherited_config did not reflect a live font-size " +
            "increase (before: \(before), after: \(after)) — the capture design " +
            "in terminal-font-size-persistence.md needs revisiting; see its " +
            "Alternatives section")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails to compile**

Run: `swift test --filter GhosttyFontSizeTests 2>&1 | tail -30`
Expected: FAIL — `value of type 'GhosttySurface' has no member 'currentFontSize'`

- [ ] **Step 3: Implement `currentFontSize()`**

In `Sources/CasperGhostty/GhosttySurface.swift`, add after `geometry()`
(currently ends at line 151), before the class's closing brace (line 152):

```swift
    /// The surface's current live font size, read via libghostty's
    /// inherited-config mechanism (the same path it uses to propagate the
    /// current, possibly runtime-adjusted, font size to a new child split).
    func currentFontSize() -> Float {
        ghostty_surface_inherited_config(surface, GHOSTTY_SURFACE_CONTEXT_WINDOW).font_size
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter GhosttyFontSizeTests 2>&1 | tail -30`
Expected: PASS (or a reported `XCTSkip` if the sandbox cannot create a live
libghostty surface — in that case, re-run in an environment that can, e.g.
via `make test`, before proceeding). A PASS confirms the design's core
assumption; a FAIL means **stop here** and revisit the design's Alternatives
section instead of continuing to Task 2.

- [ ] **Step 5: Commit**

```bash
git add Sources/CasperGhostty/GhosttySurface.swift Tests/CasperGhosttyTests/GhosttyFontSizeTests.swift
git commit -m "Spike: confirm ghostty_surface_inherited_config reflects live font-size changes"
```

---

### Task 2: Data model — `Surface.fontSize`

**Files:**
- Modify: `Sources/CasperCore/Models.swift:22-47`
- Test: `Tests/CasperCoreTests/ModelsTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `Surface.fontSize: Float?` (default `nil`), `Surface.init(id:kind:fontSize:)`
  — used by Task 5's `updateSurfaceFontSize` and Task 4/6 tests.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/CasperCoreTests/ModelsTests.swift`, right after
`testWorkspaceKindRawValues()` (after line 132):

```swift
    // MARK: - Terminal font-size persistence

    func testSurfaceFontSizeDefaultsToNilAndRoundTrips() throws {
        let withSize = Surface(kind: .terminal(cwd: "/w", command: nil), fontSize: 18.5)
        let data = try JSONEncoder().encode(withSize)
        let decoded = try JSONDecoder().decode(Surface.self, from: data)
        XCTAssertEqual(decoded, withSize)
        XCTAssertEqual(decoded.fontSize, 18.5)

        let withoutSize = Surface(kind: .terminal(cwd: "/w", command: nil))
        XCTAssertNil(withoutSize.fontSize)
    }

    func testSurfaceLegacyDecodeWithoutFontSizeDefaultsToNil() throws {
        // A `session.json` written before font-size persistence existed has no
        // `fontSize` key; decoding must default it to nil (libghostty's own
        // default), matching today's unpersisted behavior.
        let sid = UUID()
        let json = """
        { "id": "\\(sid.uuidString)", "kind": { "terminal": { "cwd": "/w", "command": null } } }
        """
        let decoded = try JSONDecoder().decode(Surface.self, from: Data(json.utf8))
        XCTAssertNil(decoded.fontSize)
        XCTAssertEqual(decoded.id, sid)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ModelsTests 2>&1 | tail -30`
Expected: FAIL — `extra argument 'fontSize' in call` (the `Surface.init`
doesn't accept it yet).

- [ ] **Step 3: Add `fontSize` to `Surface`**

In `Sources/CasperCore/Models.swift`, replace lines 22-35:

```swift
public struct Surface: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: Codable, Equatable, Sendable {
        case terminal(cwd: String, command: String?)
        case browser(url: URL)
    }

    public var id: UUID
    public var kind: Kind
```

with:

```swift
public struct Surface: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: Codable, Equatable, Sendable {
        case terminal(cwd: String, command: String?)
        case browser(url: URL)
    }

    public var id: UUID
    public var kind: Kind
    /// The terminal's live font size, captured after a runtime Cmd+/Cmd-/Cmd0
    /// change; `nil` means "not customized — use libghostty's own default."
    /// Only meaningful for `.terminal` surfaces; ignored for `.browser`.
    public var fontSize: Float?
```

and the initializer + `Codable` conformance (currently lines 31-34) to:

```swift
    public init(id: UUID = UUID(), kind: Kind, fontSize: Float? = nil) {
        self.id = id
        self.kind = kind
        self.fontSize = fontSize
    }

    // Full case set is required once `init(from:)` is hand-rolled; case names
    // match the property names so the synthesized `encode(to:)` keeps the same
    // on-disk keys.
    private enum CodingKeys: String, CodingKey { case id, kind, fontSize }

    /// Decodes `fontSize` as optional so legacy `session.json` files (written
    /// before font size was persisted) default it to nil, leaving that
    /// terminal at libghostty's own default — unchanged from today's
    /// behavior. `encode(to:)` stays synthesized, keeping the on-disk shape
    /// stable and forward-writing the new field.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.kind = try c.decode(Kind.self, forKey: .kind)
        self.fontSize = try c.decodeIfPresent(Float.self, forKey: .fontSize)
    }
}
```

(`Surface.terminal(cwd:command:)` at `Models.swift:39-41` needs no change —
`fontSize` defaults to `nil` there via the initializer's default.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ModelsTests 2>&1 | tail -30`
Expected: PASS, including all pre-existing `ModelsTests` (no regression in
the full-session round-trip tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CasperCore/Models.swift Tests/CasperCoreTests/ModelsTests.swift
git commit -m "Add fontSize field to Surface for per-terminal font persistence"
```

---

### Task 3: `LayoutTree.updateSurface` pure mutator

**Files:**
- Modify: `Sources/CasperCore/LayoutTree.swift:19-28` (add new method right
  after `surfaces(_:)`)
- Test: `Tests/CasperCoreTests/LayoutTreeTests.swift`

**Interfaces:**
- Consumes: `LayoutNode` (`.leaf`/`.split`, `Models.swift:54-61`), `Surface`
  (`Models.swift:22-47`, now carrying `fontSize: Float?` from Task 2).
- Produces: `LayoutTree.updateSurface(_:id:_:) -> LayoutNode` — used by
  Task 5's `AppModel.updateSurfaceFontSize`.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/CasperCoreTests/LayoutTreeTests.swift`, right after
`testSurfacesReturnsSurfaceObjectsInOrder()` (after line 29):

```swift
    // MARK: - updateSurface

    func testUpdateSurfaceMutatesMatchingLeaf() {
        let a = term(); let b = term()
        let root = LayoutNode.split(
            orientation: .horizontal, children: [leaf(a), leaf(b)], ratios: [0.5, 0.5])
        let out = LayoutTree.updateSurface(root, id: a.id) { $0.fontSize = 18 }
        guard case .split(_, let children, _) = out else { return XCTFail() }
        guard case .leaf(let updated) = children[0], case .leaf(let untouched) = children[1] else {
            return XCTFail()
        }
        XCTAssertEqual(updated.fontSize, 18)
        XCTAssertNil(untouched.fontSize)
        XCTAssertEqual(updated.id, a.id)  // identity preserved
    }

    func testUpdateSurfaceUnknownIDIsNoOp() {
        let a = term()
        let root = leaf(a)
        let out = LayoutTree.updateSurface(root, id: UUID()) { $0.fontSize = 18 }
        XCTAssertEqual(out, root)
    }

    func testUpdateSurfaceRecursesIntoNestedSplits() {
        let a = term(); let b = term(); let c = term()
        let nested = LayoutNode.split(
            orientation: .vertical, children: [leaf(b), leaf(c)], ratios: [0.5, 0.5])
        let root = LayoutNode.split(
            orientation: .horizontal, children: [leaf(a), nested], ratios: [0.5, 0.5])
        let out = LayoutTree.updateSurface(root, id: c.id) { $0.fontSize = 22 }
        let surfaces = LayoutTree.surfaces(out)
        XCTAssertEqual(surfaces.first { $0.id == c.id }?.fontSize, 22)
        XCTAssertNil(surfaces.first { $0.id == b.id }?.fontSize)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter LayoutTreeTests 2>&1 | tail -30`
Expected: FAIL — `type 'LayoutTree' has no member 'updateSurface'`

- [ ] **Step 3: Implement `updateSurface`**

In `Sources/CasperCore/LayoutTree.swift`, add right after `surfaces(_:)`
(currently ends at line 28), before `orientationAndSide`:

```swift
    /// Replace the surface with `id` in the tree by applying `transform` to
    /// it in place. Leaves the tree structurally unchanged (same shape,
    /// values equal) if `id` is not found — the `Surface`-mutating twin of
    /// `surfaceIDs`/`surfaces`, walking the same cases.
    public static func updateSurface(
        _ node: LayoutNode, id: UUID, _ transform: (inout Surface) -> Void
    ) -> LayoutNode {
        switch node {
        case .leaf(var surface):
            if surface.id == id { transform(&surface) }
            return .leaf(surface)
        case .split(let orientation, let children, let ratios):
            return .split(
                orientation: orientation,
                children: children.map { updateSurface($0, id: id, transform) },
                ratios: ratios)
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter LayoutTreeTests 2>&1 | tail -30`
Expected: PASS, including all pre-existing `LayoutTreeTests`.

- [ ] **Step 5: Commit**

```bash
git add Sources/CasperCore/LayoutTree.swift Tests/CasperCoreTests/LayoutTreeTests.swift
git commit -m "Add LayoutTree.updateSurface pure mutator"
```

---

### Task 4: `GhosttySurfaceView.onFontSizeChange`

**Files:**
- Modify: `Sources/CasperGhostty/GhosttySurfaceView.swift:11-71` (init +
  stored properties) and `:398-408` (the three font-size actions)
- Test: `Tests/CasperGhosttyTests/GhosttyFontSizeTests.swift` (from Task 1)

**Interfaces:**
- Consumes: `GhosttySurface.currentFontSize() -> Float` (Task 1),
  `GhosttySurface.bindingAction(_:) -> Bool` (already existing).
- Produces: `GhosttySurfaceView.onFontSizeChange: (UUID, Float) -> Void`
  (settable, default no-op) — used by Task 5's `AppModel.surfaceView(for:in:)`.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/CasperGhosttyTests/GhosttyFontSizeTests.swift`, inside
`GhosttyFontSizeTests`, after the spike test from Task 1:

```swift
    /// `increaseFontSize` must read the new size back and forward it (with the
    /// surface's own id) to `onFontSizeChange`. Real runtime + real window,
    /// same precondition-skip pattern as the spike test above.
    @MainActor
    func testIncreaseFontSizeReportsChangedSizeToClosure() throws {
        let runtime = try GhosttyRuntime()
        var reported: (UUID, Float)?
        let surfaceID = UUID()
        let view = GhosttySurfaceView(
            runtime: runtime, configuration: GhosttySurfaceConfiguration(), surfaceID: surfaceID,
            onFontSizeChange: { id, size in reported = (id, size) })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view

        let deadline = Date().addingTimeInterval(10)
        while view.surface == nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        guard view.surface != nil else {
            throw XCTSkip("libghostty could not create a surface in this environment")
        }

        view.increaseFontSize(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        let (reportedID, reportedSize) = try XCTUnwrap(reported)
        XCTAssertEqual(reportedID, surfaceID)
        XCTAssertGreaterThan(reportedSize, 0)
    }

    /// Without a live surface (the `.forTesting()` runtime never creates one),
    /// the font-size actions must not invoke the closure at all — deterministic
    /// and surfaceless, no window/polling needed.
    @MainActor
    func testFontSizeChangeClosureDoesNotFireWithoutALiveSurface() {
        var firedCount = 0
        let view = GhosttySurfaceView(
            runtime: .forTesting(), configuration: GhosttySurfaceConfiguration(),
            onFontSizeChange: { _, _ in firedCount += 1 })
        view.increaseFontSize(nil)
        view.decreaseFontSize(nil)
        view.resetFontSize(nil)
        XCTAssertEqual(firedCount, 0)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter GhosttyFontSizeTests 2>&1 | tail -30`
Expected: FAIL — `incorrect argument label in call` /
`extra argument 'onFontSizeChange' in call` (the initializer doesn't accept
it yet).

- [ ] **Step 3: Add `onFontSizeChange` to `GhosttySurfaceView`**

In `Sources/CasperGhostty/GhosttySurfaceView.swift`, add a stored property
after `var onContextMenu` (currently line 26):

```swift
    // Fired after a font-size action (increase/decrease/reset) changes this
    // surface's live font size, reading back via `GhosttySurface.currentFontSize()`
    // — libghostty exposes no getter to read a size change any other way.
    var onFontSizeChange: (UUID, Float) -> Void
    // The last font size reported to `onFontSizeChange`, so a font-size action
    // that libghostty clamped to a no-op (e.g. reset when already at default,
    // or increase past its max) does not re-report the same value.
    private var lastReportedFontSize: Float?
```

Update the initializer signature (currently lines 53-59):

```swift
    public init(
        runtime: GhosttyRuntime, configuration: GhosttySurfaceConfiguration,
        surfaceID: UUID = UUID(), onFocus: @escaping (UUID) -> Void = { _ in },
        onAttach: @escaping (UUID) -> Void = { _ in },
        onClose: @escaping (UUID) -> Void = { _ in },
        onContextMenu: ((NSEvent) -> NSMenu?)? = nil,
        onFontSizeChange: @escaping (UUID, Float) -> Void = { _, _ in }
    ) {
        self.surfaceID = surfaceID
        self.onFocus = onFocus
        self.onAttach = onAttach
        self.onClose = onClose
        self.onContextMenu = onContextMenu
        self.onFontSizeChange = onFontSizeChange
        self.runtime = runtime
        self.configuration = configuration
        super.init(frame: .zero)
        // libghostty attaches its own CAMetalLayer to this view.
        wantsLayer = true
        postsFrameChangedNotifications = true
    }
```

- [ ] **Step 4: Wire it into the three font-size actions**

Replace `Sources/CasperGhostty/GhosttySurfaceView.swift:398-408`:

```swift
    @objc func increaseFontSize(_ sender: Any?) {
        surface?.bindingAction("increase_font_size:1")
    }

    @objc func decreaseFontSize(_ sender: Any?) {
        surface?.bindingAction("decrease_font_size:1")
    }

    @objc func resetFontSize(_ sender: Any?) {
        surface?.bindingAction("reset_font_size")
    }
```

with:

```swift
    @objc func increaseFontSize(_ sender: Any?) {
        surface?.bindingAction("increase_font_size:1")
        reportFontSizeIfChanged()
    }

    @objc func decreaseFontSize(_ sender: Any?) {
        surface?.bindingAction("decrease_font_size:1")
        reportFontSizeIfChanged()
    }

    @objc func resetFontSize(_ sender: Any?) {
        surface?.bindingAction("reset_font_size")
        reportFontSizeIfChanged()
    }

    // Read the surface's live font size back after a binding-action font-size
    // change and forward it to `onFontSizeChange` only when it actually moved,
    // so `AppModel` is never asked to persist a no-op change.
    private func reportFontSizeIfChanged() {
        guard let surface else { return }
        let size = surface.currentFontSize()
        if size != lastReportedFontSize {
            lastReportedFontSize = size
            onFontSizeChange(surfaceID, size)
        }
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter GhosttyFontSizeTests 2>&1 | tail -30`
Expected: PASS (or `XCTSkip`, see Task 1 Step 4's note).

- [ ] **Step 6: Run the full `CasperGhostty` test target for regressions**

Run: `swift test --filter CasperGhosttyTests 2>&1 | tail -60`
Expected: PASS, no regressions (in particular `GhosttyFocusCallbackTests`,
which constructs `GhosttySurfaceView` without `onFontSizeChange` — verifying
the new parameter's default keeps existing call sites compiling).

- [ ] **Step 7: Commit**

```bash
git add Sources/CasperGhostty/GhosttySurfaceView.swift Tests/CasperGhosttyTests/GhosttyFontSizeTests.swift
git commit -m "Report live font-size changes from GhosttySurfaceView"
```

---

### Task 5: `AppModel` capture + restore wiring

**Files:**
- Modify: `Sources/CasperUI/AppModel.swift:786-801` (`surfaceView(for:in:)`),
  `:946-959` (add `updateSurfaceFontSize` after `setInspectorWidth`),
  `:995-1011` (`surfaceConfiguration(for:terminal:)`)
- Test: `Tests/CasperUITests/AppModelTests.swift`

**Interfaces:**
- Consumes: `LayoutTree.updateSurface(_:id:_:)` (Task 3),
  `GhosttySurfaceView.onFontSizeChange` (Task 4), `Surface.fontSize` (Task 2),
  `AppModel.locateSurface(_:) -> (space: Int, workspace: Int)?`
  (`AppModel.swift:651-653`, private, same file), `AppModel.scheduleSave()`
  (`AppModel.swift:980-985`, private, same file).
- Produces: `AppModel.updateSurfaceFontSize(_ surfaceID: UUID, size: Float)` —
  used by Task 6's integration test and wired into `surfaceView(for:in:)`
  below. `GhosttySurfaceConfiguration.fontSize` now carries
  `terminal.fontSize ?? 0` instead of the implicit default `0`.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/CasperUITests/AppModelTests.swift`, right after
`testSetBrowserURLWritesBackToInspectorBrowserWhenNotInLayout` and its
closing brace (find it after line ~865; add these as new top-level methods
in the class, anywhere after `modelWithOnePlainWorkspace()` is defined):

```swift
    // MARK: - Terminal font-size persistence

    func testSurfaceConfigurationPassesPersistedFontSizeOrDefaultsToZero() {
        let (model, _) = modelWithOnePlainWorkspace()
        let workspace = model.spaces[0].workspaces[0]
        let sized = Surface(kind: .terminal(cwd: workspace.worktreePath, command: nil), fontSize: 22)
        let unsized = Surface(kind: .terminal(cwd: workspace.worktreePath, command: nil))

        XCTAssertEqual(model.surfaceConfiguration(for: workspace, terminal: sized).fontSize, 22)
        XCTAssertEqual(model.surfaceConfiguration(for: workspace, terminal: unsized).fontSize, 0)
    }

    func testUpdateSurfaceFontSizeUpdatesLayoutAndSchedulesSave() {
        let (model, surfaceID) = modelWithOnePlainWorkspace()
        var saves = 0
        model.onPersistForTest = { saves += 1 }

        model.updateSurfaceFontSize(surfaceID, size: 20)

        let surface = LayoutTree.surfaces(model.spaces[0].workspaces[0].layout)
            .first { $0.id == surfaceID }
        XCTAssertEqual(surface?.fontSize, 20)

        model.flushPendingSave()  // debounced; flush so the assertion is deterministic
        XCTAssertEqual(saves, 1)
    }

    func testUpdateSurfaceFontSizeUnknownSurfaceIsNoOp() {
        let (model, _) = modelWithOnePlainWorkspace()
        let layoutBefore = model.spaces[0].workspaces[0].layout
        model.updateSurfaceFontSize(UUID(), size: 20)
        XCTAssertEqual(model.spaces[0].workspaces[0].layout, layoutBefore)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AppModelTests 2>&1 | tail -40`
Expected: FAIL — `value of type 'GhosttySurfaceConfiguration' has no member
'fontSize'` is not the error (that member already exists); instead:
`value of type 'AppModel' has no member 'updateSurfaceFontSize'`, and the
first test's `.fontSize` assertion fails (currently always `0` regardless of
`terminal.fontSize`).

- [ ] **Step 3: Add `updateSurfaceFontSize` and wire the two chokepoints**

In `Sources/CasperUI/AppModel.swift`, add this method right after
`setInspectorWidth` (currently ends at line 959), before
`discardSurfaceViews`:

```swift
    /// Record a terminal surface's live font size (reported after a
    /// Cmd+/Cmd-/Cmd0 change forwarded to libghostty) into its persisted
    /// `Surface`, and schedule the existing debounced save — mirrors
    /// `setInspectorWidth`'s drag-persistence pattern.
    func updateSurfaceFontSize(_ surfaceID: UUID, size: Float) {
        guard let at = locateSurface(surfaceID) else { return }
        spaces[at.space].workspaces[at.workspace].layout = LayoutTree.updateSurface(
            spaces[at.space].workspaces[at.workspace].layout, id: surfaceID
        ) { $0.fontSize = size }
        scheduleSave()
    }
```

Replace `surfaceView(for:in:)` (currently lines 786-801):

```swift
    /// The persistent view for a terminal surface, created on first use. Returns nil
    /// for a non-terminal surface or before the runtime exists.
    func surfaceView(for surface: Surface, in workspace: Workspace) -> GhosttySurfaceView? {
        guard let runtime, case .terminal = surface.kind else { return nil }
        if let existing = surfaceViews[surface.id] as? GhosttySurfaceView {
            return existing
        }
        let view = GhosttySurfaceView(
            runtime: runtime,
            configuration: surfaceConfiguration(for: workspace, terminal: surface),
            surfaceID: surface.id,
            onFocus: { [weak self] id in self?.focusSurface(id) },
            onAttach: { [weak self] id in self?.focusSurfaceViewIfActive(id) },
            onClose: { [weak self] id in self?.applyCloseSurface(id) },
            onContextMenu: { [weak self, id = surface.id] _ in self?.paneContextMenu(for: id) },
            onFontSizeChange: { [weak self] id, size in self?.updateSurfaceFontSize(id, size: size) })
        surfaceViews[surface.id] = view
        return view
    }
```

Replace `surfaceConfiguration(for:terminal:)` (currently lines 995-1011):

```swift
    /// The per-surface environment injected into a terminal so the `casper` CLI
    /// resolves and the agent sees its reserved ports.
    func surfaceConfiguration(
        for workspace: Workspace, terminal: Surface
    ) -> GhosttySurfaceConfiguration {
        guard case .terminal(let cwd, let command) = terminal.kind else {
            return GhosttySurfaceConfiguration()
        }
        var config = GhosttySurfaceConfiguration(
            workingDirectory: cwd, command: command, fontSize: terminal.fontSize ?? 0)
        config.environment = ClaudeCodeAdapter.surfaceEnvironment(
            workspaceId: workspace.id,
            portBase: workspace.portBase,
            casperDirectory: casperDirectory,
            basePath: ProcessInfo.processInfo.environment["PATH"],
            controlSocketPath: controlSocketPath,
            sessionName: sessionIdentity.name
        )
        return config
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AppModelTests 2>&1 | tail -60`
Expected: PASS, including all pre-existing `AppModelTests` (in particular
`testApplyNewTerminalBlursPreviouslyFocusedSurface` and
`testApplySplitFromNonFocusedSurfaceBlursTheFocusedSurface`, which also call
`surfaceView(for:in:)`).

- [ ] **Step 5: Commit**

```bash
git add Sources/CasperUI/AppModel.swift Tests/CasperUITests/AppModelTests.swift
git commit -m "Wire terminal font-size capture and restore into AppModel"
```

---

### Task 6: End-to-end integration test (real surface, full wiring)

**Files:**
- Test: `Tests/CasperUITests/AppModelTests.swift`

**Interfaces:**
- Consumes: everything produced by Tasks 2-5 — no new production code in
  this task, verification only.

- [ ] **Step 1: Write the integration test**

Add to `Tests/CasperUITests/AppModelTests.swift`, in the "Focus and layout
mutations" section near `testApplyNewTerminalBlursPreviouslyFocusedSurface`
(both already use `model.runtime = try GhosttyRuntime()`):

```swift
    /// Full wiring, real libghostty surface: adjusting font size through the
    /// live view must update the exact matching `Surface` in the model and
    /// schedule a save — the whole capture path (Task 4's
    /// `onFontSizeChange` -> Task 5's `updateSurfaceFontSize` -> Task 3's
    /// `LayoutTree.updateSurface`) exercised together, not just unit-by-unit.
    @MainActor
    func testLiveFontSizeChangeFlowsFromViewIntoModelAndSchedulesSave() throws {
        let (model, surfaceID) = try modelWithOneGitWorkspace()
        model.runtime = try GhosttyRuntime()
        var saves = 0
        model.onPersistForTest = { saves += 1 }

        let workspace = model.spaces[0].workspaces[0]
        let surface = LayoutTree.surfaces(workspace.layout).first { $0.id == surfaceID }!
        let view = try XCTUnwrap(model.surfaceView(for: surface, in: workspace))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view  // triggers viewDidMoveToWindow -> ghostty_surface_new

        let deadline = Date().addingTimeInterval(10)
        while view.surface == nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        guard view.surface != nil else {
            throw XCTSkip("libghostty could not create a surface in this environment")
        }

        view.increaseFontSize(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        let updated = LayoutTree.surfaces(model.spaces[0].workspaces[0].layout)
            .first { $0.id == surfaceID }
        let updatedFontSize = try XCTUnwrap(updated?.fontSize)
        XCTAssertGreaterThan(updatedFontSize, 0)

        model.flushPendingSave()
        XCTAssertGreaterThanOrEqual(saves, 1)
    }
```

- [ ] **Step 2: Run the test**

Run: `swift test --filter testLiveFontSizeChangeFlowsFromViewIntoModelAndSchedulesSave 2>&1 | tail -40`
Expected: PASS (or `XCTSkip` per the environment caveat noted in Task 1).

- [ ] **Step 3: Run the full test suite for regressions**

Run: `make test 2>&1 | tail -80`
Expected: PASS, no regressions anywhere in the suite.

- [ ] **Step 4: Commit**

```bash
git add Tests/CasperUITests/AppModelTests.swift
git commit -m "Add end-to-end test for terminal font-size persistence wiring"
```

---

### Task 7: Full-suite verification + manual check

**Files:** none (verification only)

- [ ] **Step 1: Run the full test suite**

Run: `make test 2>&1 | tail -80`
Expected: PASS, no regressions.

- [ ] **Step 2: Manual verification via `make dev`**

Run: `make dev`, then in the app:

1. Open a terminal in one workspace; press Cmd+ (increase font size) three
   or four times.
2. Open a second terminal in a different workspace; leave its font size
   untouched.
3. Quit Casper.
4. Relaunch (`make dev` again, same branch/session).

Expected: the first terminal reopens visibly larger than before; the second,
untouched terminal reopens at the default size. This is the design's
originally-specified manual acceptance check (`.superpowers/plans/terminal-font-size-persistence.md`,
Testing section) — Task 1's automated spike test and Task 6's integration
test already give strong confidence in the underlying mechanism, so this
step is a final visual sanity pass, not a substitute for them.

- [ ] **Step 3: Commit** (only if step 2 uncovered fixes; otherwise skip)
