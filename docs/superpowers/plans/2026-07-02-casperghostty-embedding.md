# CasperGhostty Embedding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Embed libghostty (via the `GhosttyKit` C API) behind a `CasperGhostty`
module so that `casper` (no arguments) opens a native macOS window rendering one
live GPU-accelerated terminal surface running the user's shell in a chosen
directory.

**Architecture:** A single new SPM target, `CasperGhostty`, is the *only* code
that touches the unstable libghostty embedding API (per the design's hard
constraint). It exposes a main-thread-affine `GhosttyRuntime` (process init +
`ghostty_app_t` + the C runtime callbacks + the wakeup→tick pump), a
`GhosttySurface` handle (owns a `ghostty_surface_t`, frees on deinit — same
ownership pattern as `CasperGit.Repository`), an AppKit `GhosttySurfaceView`
(`NSView` that libghostty renders into and that forwards `NSEvent`s), a thin
`GhosttySurfaceRepresentable` SwiftUI bridge for Plan 5, and a `GhosttyDemo`
that stands up a minimal `NSApplication`/`NSWindow` for the end-to-end
deliverable. Automated tests cover the *pure* Swift-side logic (action decoding,
config marshaling, modifier mapping, callback trampolines); live rendering and
input are covered by a documented manual checklist (consistent with design §13,
which lists terminal rendering/keyboard/focus as manual).

**Tech Stack:** Swift 6 / SwiftPM, AppKit (`NSView`, `NSEvent`,
`NSTextInputClient`, `NSWindow`), SwiftUI (`NSViewRepresentable`), and the
`GhosttyKit` C module vended by the pinned `Lakr233/libghostty-spm` binary
package.

## Global Constraints

- **Platform:** macOS 14+, **arm64-only**. Swift 6 language mode.
- **Line length:** code 120 columns, Markdown 80 columns.
- **Dependency policy:** the only sanctioned externals are **GhosttyKit**,
  **swift-argument-parser**, **libgit2**. `CasperGhostty` consumes **only** the
  `GhosttyKit` product from `Lakr233/libghostty-spm` (the raw C-API re-export) —
  **never** `GhosttyTerminal`/`ShellCraftKit`/`GhosttyTheme` (those pull the
  extra `MSDisplayLink` dependency and duplicate the layer Casper owns itself).
- **API isolation:** every `ghostty_*` symbol and `import GhosttyKit` lives
  **only** inside the `CasperGhostty` target. No other module imports GhosttyKit.
- **Pinned libghostty version (record verbatim):**
  - Package: `Lakr233/libghostty-spm` pinned `exact: "1.2.8"`.
  - binaryTarget asset:
    `https://github.com/Lakr233/libghostty-spm/releases/download/storage.1.2.8/GhosttyKit.xcframework.zip`
    checksum `eab8ecf086806acd6c0cfa198635c70e8b711c3a4d449bb0eb79b717b3960e24`
    (this is what the package's own `Package.swift@1.2.8` declares; SPM verifies
    it on resolve).
  - Upstream libghostty = **Ghostty `v1.3.1`**, SHA
    `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28` (+ Lakr233 patches).
  - **Header source of truth = the v1.3.1 header, NOT `main`.** `main` inserts
    `GHOSTTY_ACTION_SELECTION_CHANGED` mid-enum, renumbering every later action
    tag. Raw:
    `https://raw.githubusercontent.com/ghostty-org/ghostty/v1.3.1/include/ghostty.h`
- **Working against an unstable C API without a compiler in hand:** Task 1
  vendors that exact header into `Vendor/ghostty/ghostty.h` declaratively via
  **Carvel `vendir`** (`vendir.yml` + checksum-locked `vendir.lock.yml`, so the
  header pin is reproducible and re-syncable — not a one-off `curl`). Every
  later task that names
  a `ghostty_*` struct field, enum member, or function signature MUST be
  confirmed against `Vendor/ghostty/ghostty.h` before writing the call. Points flagged
  **⚠ confirm** below are the specific spots most likely to differ from the code
  shown; the code shown is the intended shape, the vendored header is the truth.
- **Never crash policy:** surface failures as thrown `GhosttyError`, mirroring
  `CasperGit.GitError`. The single sanctioned `precondition` exception is an
  unrecoverable one-time process init failure (mirrors `Libgit2.ensureInit`).
- **Build/test:** `make build`, `make test`. Tests need the full Xcode toolchain
  (`sudo xcode-select -s /Applications/Xcode.app`). XCTest files using
  Foundation types must `import Foundation`.
- **Code edits go through the `skillbox:code-writer` agent** (project rule): do
  not hand-edit source; delegate each implementation step.

## Scope Boundary (explicit)

**In this plan:** the `CasperGhostty` module, one live terminal surface end to
end, and the pure-logic test suite. **Deferred to Plan 5 (CasperUI), by
decision:** multi-surface splits/tabs *layout composition* and the interception
of `NEW_SPLIT`/`NEW_TAB`/`GOTO_SPLIT`/`RESIZE_SPLIT`/`MOVE_TAB` actions. This
plan still *decodes* those actions into `GhosttyAction` cases (so Plan 5 can act
on them) but takes no layout action beyond logging them.

## File Structure

- `Package.swift` (modify) — add the `libghostty-spm` package dependency, the
  `CasperGhostty` target + product + test target, and a `CasperGhostty`
  dependency on the `casper` executable target.
- `vendir.yml` (create) — Carvel vendir config declaring the pinned v1.3.1
  header (URL + sha256). The reproducible source of the vendored header.
- `vendir.lock.yml` (create) — vendir lock, written by `vendir sync`.
- `Vendor/ghostty/ghostty.h` (synced by vendir) — pinned v1.3.1 header, reference
  only (not compiled; the module comes from the xcframework). Managed by vendir —
  do not hand-edit.
- `Sources/CasperGhostty/CasperGhostty.swift` (create) — module doc + the
  `GhosttyError` type + a `pinnedGhosttyVersion` constant.
- `Sources/CasperGhostty/GhosttyAction.swift` (create) — `GhosttyAction` enum +
  pure `decode(_:)`. Fully unit-tested.
- `Sources/CasperGhostty/GhosttyRuntime.swift` (create) — app/config lifecycle,
  the C runtime callbacks (free-function trampolines), wakeup→tick pump,
  `onAction` closure.
- `Sources/CasperGhostty/GhosttySurfaceConfiguration.swift` (create) — Swift
  config struct + `withCValue` C-struct builder (env-var marshaling).
- `Sources/CasperGhostty/GhosttySurface.swift` (create) — `ghostty_surface_t`
  handle: size/scale/focus/draw + input forwarding.
- `Sources/CasperGhostty/GhosttyInput.swift` (create) — pure NSEvent→C mapping
  helpers (`ghosttyMods(from:)`, key-event builder). Unit-tested.
- `Sources/CasperGhostty/GhosttySurfaceView.swift` (create) — AppKit `NSView`
  host + `NSTextInputClient`.
- `Sources/CasperGhostty/GhosttySurfaceRepresentable.swift` (create) — SwiftUI
  `NSViewRepresentable` bridge (for Plan 5).
- `Sources/CasperGhostty/GhosttyDemo.swift` (create) — minimal
  `NSApplication`/`NSWindow` launcher; `public static func run(directory:)`.
- `Sources/casper/main.swift` (modify) — GUI mode calls `GhosttyDemo.run(...)`.
- `Tests/CasperGhosttyTests/GhosttyActionTests.swift` (create)
- `Tests/CasperGhosttyTests/GhosttySurfaceConfigurationTests.swift` (create)
- `Tests/CasperGhosttyTests/GhosttyInputTests.swift` (create)
- `Tests/CasperGhosttyTests/GhosttyRuntimeTrampolineTests.swift` (create)

---

### Task 1: Vendor the pinned header, wire the package, smoke-import GhosttyKit

**Files:**
- Modify: `Package.swift`
- Create: `vendir.yml`
- Create: `vendir.lock.yml` (generated by `vendir sync`)
- Create: `Vendor/ghostty/ghostty.h` (synced by vendir)
- Modify: `Makefile` (add a `vendor` target)
- Create: `Sources/CasperGhostty/CasperGhostty.swift`
- Test: `Tests/CasperGhosttyTests/SmokeTests.swift`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: the `CasperGhostty` target that `import GhosttyKit` links against;
  the `GhosttyError` type (`struct GhosttyError: Error, Equatable, Sendable`
  with `let reason: String`); the `pinnedGhosttyVersion: String` constant
  (`"v1.3.1"`).

- [ ] **Step 1: Add the package dependency and target to `Package.swift`**

Add to `dependencies:`:

```swift
.package(
    url: "https://github.com/Lakr233/libghostty-spm.git",
    exact: "1.2.8"
),
```

Add to `products:`:

```swift
.library(name: "CasperGhostty", targets: ["CasperGhostty"]),
```

Add to `targets:` (place after the `CasperAgents` target):

```swift
.target(
    name: "CasperGhostty",
    dependencies: [
        .product(name: "GhosttyKit", package: "libghostty-spm"),
    ],
    linkerSettings: [
        .linkedLibrary("c++"),
        .linkedFramework("Carbon", .when(platforms: [.macOS])),
    ]
),
```

Add a test target:

```swift
.testTarget(
    name: "CasperGhosttyTests",
    dependencies: ["CasperGhostty"]
),
```

Add `CasperGhostty` to the `casper` executable target's dependencies (it
currently lists only `"CasperCLI"`):

```swift
.executableTarget(name: "casper", dependencies: ["CasperCLI", "CasperGhostty"]),
```

- [ ] **Step 2: Vendor the pinned header with Carvel `vendir`**

Requires `vendir` (`brew install vendir` — Carvel's declarative file-vendoring
tool; a dev tool, not a linked dependency, so it does not touch the three-external
runtime-dependency policy). Confirm: `vendir version` (expect ≥ 0.40.0).

Create `vendir.yml` at the repo root (the `sha256` is the verified digest of the
v1.3.1 header — vendir refuses to sync any other content):

```yaml
apiVersion: vendir.k14s.io/v1alpha1
kind: Config
minimumRequiredVersion: 0.40.0
directories:
  - path: Vendor
    contents:
      # Pinned libghostty header — the source of truth for every ghostty_* symbol
      # used by CasperGhostty. Ghostty tag v1.3.1, SHA
      # 332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28. NOT compiled (the module comes
      # from the GhosttyKit xcframework); vendored for reference only.
      - path: ghostty
        http:
          url: https://raw.githubusercontent.com/ghostty-org/ghostty/v1.3.1/include/ghostty.h
          sha256: a619c107e9ab8841f71f91d06bf2bcea7b7c64bf6df252b151812cb932ac9b61
```

Run: `vendir sync`
Expected: writes `Vendor/ghostty/ghostty.h` (1178 lines) and `vendir.lock.yml`.
If vendir reports a checksum mismatch, STOP — the pin is wrong; do not replace
the sha256 with vendir's computed value.

Verify the pin: `grep -c ghostty_action_tag_e Vendor/ghostty/ghostty.h` > 0, and
`grep GHOSTTY_ACTION_SELECTION_CHANGED Vendor/ghostty/ghostty.h` prints
**nothing** (that member is `main`-only; its absence confirms v1.3.1).

Both `vendir.yml`, `vendir.lock.yml`, and `Vendor/` are committed — do **not**
gitignore them (the header is small text and is the API ground truth).

Add a convenience target to the `Makefile` (after `clean`), and list it in the
`## ` help block:

```make
## vendor: re-sync vendored files (pinned libghostty header) via Carvel vendir
vendor:
	vendir sync
```

- [ ] **Step 3: Write the module file**

`Sources/CasperGhostty/CasperGhostty.swift`:

```swift
import GhosttyKit

/// CasperGhostty is the *only* module that touches the unstable libghostty
/// embedding API. Everything `ghostty_*` is confined here (see the design's
/// hard constraint on API isolation). A libghostty version bump touches only
/// this target.
///
/// Pinned to Ghostty `v1.3.1` via the `Lakr233/libghostty-spm` `1.2.8` binary
/// package. See `Vendor/ghostty/ghostty.h` for the exact API this code is written
/// against, and the project memory note for the full pin.
public enum CasperGhostty {
    /// The upstream Ghostty tag the linked GhosttyKit was built from.
    public static let pinnedGhosttyVersion = "v1.3.1"
}

/// A libghostty embedding failure, surfaced instead of crashing (mirrors
/// `CasperGit.GitError`). Carries a human-readable reason.
public struct GhosttyError: Error, Equatable, Sendable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
}
```

- [ ] **Step 4: Write the smoke test**

`Tests/CasperGhosttyTests/SmokeTests.swift`:

```swift
import XCTest
@testable import CasperGhostty

final class SmokeTests: XCTestCase {
    func testModuleLinksAndExposesPin() {
        XCTAssertEqual(CasperGhostty.pinnedGhosttyVersion, "v1.3.1")
    }
}
```

- [ ] **Step 5: Resolve, build, and run the smoke test**

Run: `swift package resolve`
Expected: downloads `GhosttyKit.xcframework.zip` (~53 MB) and verifies the
checksum. If SPM reports a checksum mismatch, STOP — the pin in the Global
Constraints is wrong; do not "fix" it by pasting SPM's computed value.

Run: `make build`
Expected: PASS — the `import GhosttyKit` in `CasperGhostty.swift` compiles and
links (proves the xcframework + linker settings are correct).

Run: `swift test --filter CasperGhosttyTests.SmokeTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Package.resolved vendir.yml vendir.lock.yml \
    Vendor/ghostty/ghostty.h Makefile \
    Sources/CasperGhostty/CasperGhostty.swift Tests/CasperGhosttyTests/SmokeTests.swift
git commit -m "Add CasperGhostty target linking the pinned GhosttyKit xcframework"
```

---

### Task 2: `GhosttyAction` — decode libghostty actions (pure, fully tested)

**Files:**
- Create: `Sources/CasperGhostty/GhosttyAction.swift`
- Test: `Tests/CasperGhosttyTests/GhosttyActionTests.swift`

**Interfaces:**
- Consumes: `GhosttyKit` C types (`ghostty_action_s`, `ghostty_action_tag_e`,
  and the union payload structs).
- Produces:
  - `enum GhosttyAction: Equatable` with cases:
    `.setTitle(String)`, `.setTabTitle(String)`, `.pwd(String)`,
    `.ringBell`, `.render`, `.childExited(exitCode: Int32)`,
    `.desktopNotification(title: String, body: String)`,
    `.newSplit(GhosttySplitDirection)`, `.newTab`, `.newWindow`,
    `.closeTab`, `.closeWindow`, `.other(tag: UInt32)`
  - `enum GhosttySplitDirection: Equatable { case right, down, left, up }`
  - `static func decode(_ c: ghostty_action_s) -> GhosttyAction`
    (returns `.other(tag:)` for any tag not explicitly modeled — never nil, so
    callers get a total function).

**⚠ confirm against `Vendor/ghostty/ghostty.h`:** the exact union member names
(`c.action.set_title`, `c.action.pwd`, `c.action.new_split`,
`c.action.child_exited`, `c.action.desktop_notification`) and each payload
struct's field names (`.title`, `.pwd`, `.direction`, `.exit_code`, `.title`/
`.body`). The strings are `const char*` (`UnsafePointer<CChar>?`) → decode with
`String(cString:)` guarding nil. The tag enum is `ghostty_action_tag_e`; compare
with the C constants (`GHOSTTY_ACTION_SET_TITLE`, etc.), never hardcoded ints.

- [ ] **Step 1: Write the failing tests**

`Tests/CasperGhosttyTests/GhosttyActionTests.swift`:

```swift
import XCTest
import GhosttyKit
@testable import CasperGhostty

final class GhosttyActionTests: XCTestCase {
    func testDecodesSetTitle() {
        "Casper".withCString { cstr in
            var action = ghostty_action_s()
            action.tag = GHOSTTY_ACTION_SET_TITLE
            action.action.set_title.title = cstr
            XCTAssertEqual(GhosttyAction.decode(action), .setTitle("Casper"))
        }
    }

    func testDecodesPwd() {
        "/tmp/wt".withCString { cstr in
            var action = ghostty_action_s()
            action.tag = GHOSTTY_ACTION_PWD
            action.action.pwd.pwd = cstr
            XCTAssertEqual(GhosttyAction.decode(action), .pwd("/tmp/wt"))
        }
    }

    func testDecodesRingBell() {
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_RING_BELL
        XCTAssertEqual(GhosttyAction.decode(action), .ringBell)
    }

    func testUnmodeledTagBecomesOther() {
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_EQUALIZE_SPLITS
        XCTAssertEqual(
            GhosttyAction.decode(action),
            .other(tag: GHOSTTY_ACTION_EQUALIZE_SPLITS.rawValue))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter CasperGhosttyTests.GhosttyActionTests`
Expected: FAIL — `GhosttyAction` is undefined.

- [ ] **Step 3: Implement `GhosttyAction`**

`Sources/CasperGhostty/GhosttyAction.swift` (decode each tag against
`Vendor/ghostty/ghostty.h`; shape shown — confirm union/field names):

```swift
import GhosttyKit

/// The direction a new split grows, mapped from `ghostty_action_split_direction_e`.
public enum GhosttySplitDirection: Equatable {
    case right, down, left, up
}

/// A libghostty runtime action, decoded from the C `action_cb` callback into a
/// Swift-native value. `CasperGhostty` handles the surface-level actions
/// (title, pwd, bell, render, notifications); layout actions (split/tab/window)
/// are decoded here but acted on by CasperUI in Plan 5.
public enum GhosttyAction: Equatable {
    case setTitle(String)
    case setTabTitle(String)
    case pwd(String)
    case ringBell
    case render
    case childExited(exitCode: Int32)
    case desktopNotification(title: String, body: String)
    case newSplit(GhosttySplitDirection)
    case newTab
    case newWindow
    case closeTab
    case closeWindow
    /// Any action tag CasperGhostty does not model yet; carries the raw tag so
    /// callers can log or extend without this enum being a bottleneck.
    case other(tag: UInt32)

    /// Total decode: every tag maps to a case (`.other` for the unmodeled).
    public static func decode(_ c: ghostty_action_s) -> GhosttyAction {
        switch c.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            return .setTitle(Self.string(c.action.set_title.title))
        case GHOSTTY_ACTION_SET_TAB_TITLE:
            return .setTabTitle(Self.string(c.action.set_tab_title.title))
        case GHOSTTY_ACTION_PWD:
            return .pwd(Self.string(c.action.pwd.pwd))
        case GHOSTTY_ACTION_RING_BELL:
            return .ringBell
        case GHOSTTY_ACTION_RENDER:
            return .render
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            return .childExited(exitCode: Int32(c.action.child_exited.exit_code))
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            return .desktopNotification(
                title: Self.string(c.action.desktop_notification.title),
                body: Self.string(c.action.desktop_notification.body))
        case GHOSTTY_ACTION_NEW_SPLIT:
            return .newSplit(Self.direction(c.action.new_split.direction))
        case GHOSTTY_ACTION_NEW_TAB:
            return .newTab
        case GHOSTTY_ACTION_NEW_WINDOW:
            return .newWindow
        case GHOSTTY_ACTION_CLOSE_TAB:
            return .closeTab
        case GHOSTTY_ACTION_CLOSE_WINDOW:
            return .closeWindow
        default:
            return .other(tag: c.tag.rawValue)
        }
    }

    private static func string(_ ptr: UnsafePointer<CChar>?) -> String {
        guard let ptr else { return "" }
        return String(cString: ptr)
    }

    private static func direction(
        _ d: ghostty_action_split_direction_e
    ) -> GhosttySplitDirection {
        switch d {
        case GHOSTTY_SPLIT_DIRECTION_RIGHT: return .right
        case GHOSTTY_SPLIT_DIRECTION_DOWN: return .down
        case GHOSTTY_SPLIT_DIRECTION_LEFT: return .left
        case GHOSTTY_SPLIT_DIRECTION_UP: return .up
        default: return .right
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter CasperGhosttyTests.GhosttyActionTests`
Expected: PASS. If a union member or enum constant name mismatches, fix it
against `Vendor/ghostty/ghostty.h` (this is expected reconciliation, not a redesign).

- [ ] **Step 5: Commit**

```bash
git add Sources/CasperGhostty/GhosttyAction.swift \
    Tests/CasperGhosttyTests/GhosttyActionTests.swift
git commit -m "Decode libghostty runtime actions into a Swift GhosttyAction enum"
```

---

### Task 3: `GhosttyRuntime` — app lifecycle, C callbacks, wakeup→tick pump

**Files:**
- Create: `Sources/CasperGhostty/GhosttyRuntime.swift`
- Test: `Tests/CasperGhosttyTests/GhosttyRuntimeTrampolineTests.swift`

**Interfaces:**
- Consumes: `GhosttyAction.decode(_:)`; `GhosttyError`.
- Produces:
  - `final class GhosttyRuntime` (main-thread affine, **not** `Sendable`):
    - `init() throws` — `ghostty_init` (once, process-wide) + config +
      `ghostty_app_new` with the runtime callbacks; throws `GhosttyError` on
      failure.
    - `var onAction: ((GhosttyAction) -> Void)?` — invoked on the main thread
      for each decoded action.
    - `var app: ghostty_app_t { get }` — the raw app handle, consumed by
      `GhosttySurface` (package-internal via `internal`, exposed to the module).
    - `func tick()` — calls `ghostty_app_tick` on the main thread.
    - `deinit` — `ghostty_app_free`.
  - Free-function C trampolines `casperGhosttyWakeup`, `casperGhosttyAction`
    (file-private-visible to the test via `@testable`) that recover the
    `GhosttyRuntime` from `userdata` and dispatch.

**⚠ confirm against `Vendor/ghostty/ghostty.h`:** field names of
`ghostty_runtime_config_s` (`userdata`, `wakeup_cb`, `action_cb`,
`read_clipboard_cb`, `confirm_read_clipboard_cb`, `write_clipboard_cb`,
`close_surface_cb`, `supports_selection_clipboard`), the `action_cb` return type
(`bool`) and argument tuple `(ghostty_app_t, ghostty_target_s, ghostty_action_s)`,
and the `ghostty_init(uintptr_t, char**)` signature. Clipboard callbacks are
stubbed minimally in this task (copy/paste polish is Plan 5); provide non-null
function pointers so libghostty never dereferences null.

- [ ] **Step 1: Write the failing trampoline test**

The app-creation path needs a GPU/GUI session, so it is *not* unit-tested here
(it is exercised by the Task 7 manual checklist). What *is* pure and testable:
the trampoline that recovers the Swift object from `userdata` and routes a
decoded action to `onAction`. Test it by calling the C-ABI function directly.

`Tests/CasperGhosttyTests/GhosttyRuntimeTrampolineTests.swift`:

```swift
import XCTest
import GhosttyKit
@testable import CasperGhostty

final class GhosttyRuntimeTrampolineTests: XCTestCase {
    func testActionTrampolineRoutesToOnAction() {
        // A runtime built without touching libghostty app creation.
        let runtime = GhosttyRuntime.forTesting()
        var received: GhosttyAction?
        runtime.onAction = { received = $0 }

        let userdata = Unmanaged.passUnretained(runtime).toOpaque()
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_RING_BELL
        var target = ghostty_target_s()
        target.tag = GHOSTTY_TARGET_APP

        _ = casperGhosttyAction(nil, target, action, userdata)

        XCTAssertEqual(received, .ringBell)
    }
}
```

**⚠ confirm** the real `action_cb` typedef: on v1.3.1 it is
`bool (*)(ghostty_app_t, ghostty_target_s, ghostty_action_s)` with `userdata`
reached via `ghostty_app_userdata(app)` **or** carried as a trailing param —
check the header. If `userdata` is *not* a callback parameter, obtain it inside
the trampoline via the app handle instead, and adjust `casperGhosttyAction`'s
signature + this test accordingly. The test's intent (trampoline → `onAction`)
stays the same.

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter CasperGhosttyTests.GhosttyRuntimeTrampolineTests`
Expected: FAIL — `GhosttyRuntime`/`casperGhosttyAction` undefined.

- [ ] **Step 3: Implement `GhosttyRuntime` and the trampolines**

`Sources/CasperGhostty/GhosttyRuntime.swift`:

```swift
import AppKit
import GhosttyKit

/// Process-wide libghostty init. `ghostty_init` must run exactly once before any
/// app/config call (mirrors `CasperGit.Libgit2.ensureInit`).
private let ghosttyInitialized: Bool = {
    // ghostty_init(argc, argv): pass the real process args.
    var argv = CommandLine.unsafeArgv
    return ghostty_init(UInt(CommandLine.argc), argv) == 0
}()

/// Owns a libghostty `ghostty_app_t` and the runtime callbacks. Main-thread
/// affine; not `Sendable` (use from the main thread only, like all AppKit).
public final class GhosttyRuntime {
    private(set) var app: ghostty_app_t!

    /// Invoked on the main thread with each decoded runtime action.
    public var onAction: ((GhosttyAction) -> Void)?

    /// Build a runtime and create the libghostty app. Throws on init failure.
    public init() throws {
        precondition(ghosttyInitialized, "ghostty_init failed")  // unrecoverable

        guard let config = ghostty_config_new() else {
            throw GhosttyError(reason: "ghostty_config_new returned null")
        }
        ghostty_config_load_default_files(config)
        ghostty_config_finalize(config)
        defer { ghostty_config_free(config) }

        var runtime = ghostty_runtime_config_s()
        runtime.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtime.supports_selection_clipboard = false
        runtime.wakeup_cb = casperGhosttyWakeup
        runtime.action_cb = casperGhosttyAction
        runtime.read_clipboard_cb = casperGhosttyReadClipboard
        runtime.confirm_read_clipboard_cb = casperGhosttyConfirmReadClipboard
        runtime.write_clipboard_cb = casperGhosttyWriteClipboard
        runtime.close_surface_cb = casperGhosttyCloseSurface

        guard let app = ghostty_app_new(&runtime, config) else {
            throw GhosttyError(reason: "ghostty_app_new returned null")
        }
        self.app = app
    }

    /// Test-only constructor: a runtime with no libghostty app, for exercising
    /// the pure trampoline routing without a GPU/GUI session.
    static func forTesting() -> GhosttyRuntime {
        GhosttyRuntime(uninitialized: ())
    }

    private init(uninitialized: ()) {
        self.app = nil
    }

    /// Drain libghostty's pending work. Main thread only.
    public func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    /// Route a decoded action to `onAction` (called by the trampoline on main).
    func dispatch(_ action: GhosttyAction) {
        onAction?(action)
    }

    deinit {
        if let app { ghostty_app_free(app) }
    }
}

// MARK: - C trampolines
//
// C function pointers can't capture Swift context, so these free functions
// recover the `GhosttyRuntime` from `userdata` (an unretained pointer set in
// the runtime config) and marshal back to the main thread where required.

func casperGhosttyWakeup(_ userdata: UnsafeMutableRawPointer?) {
    guard let userdata else { return }
    let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(userdata).takeUnretainedValue()
    // wakeup may fire off the main thread; tick must run on main.
    DispatchQueue.main.async { runtime.tick() }
}

@discardableResult
func casperGhosttyAction(
    _ app: ghostty_app_t?,
    _ target: ghostty_target_s,
    _ action: ghostty_action_s,
    _ userdata: UnsafeMutableRawPointer?
) -> Bool {
    guard let userdata else { return false }
    let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(userdata).takeUnretainedValue()
    let decoded = GhosttyAction.decode(action)
    runtime.dispatch(decoded)
    return true
}

// Minimal clipboard/close callbacks — non-null so libghostty never derefs null.
// Full copy/paste fidelity is a Plan 5 refinement.

func casperGhosttyWriteClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ content: UnsafePointer<ghostty_clipboard_content_s>?,
    _ count: Int,
    _ confirm: Bool
) {
    // ⚠ confirm signature; write plain text to NSPasteboard.general.
}

func casperGhosttyReadClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?
) -> Bool {
    return false  // deny by default in Plan 4
}

func casperGhosttyConfirmReadClipboard(
    _ userdata: UnsafeMutableRawPointer?,
    _ string: UnsafePointer<CChar>?,
    _ state: UnsafeMutableRawPointer?,
    _ request: ghostty_clipboard_request_e
) {}

func casperGhosttyCloseSurface(_ userdata: UnsafeMutableRawPointer?, _ processAlive: Bool) {}
```

**⚠ confirm** the exact typedef of each callback (parameter list + whether
`userdata` is a trailing arg) against `Vendor/ghostty/ghostty.h`; the wakeup/action
trampolines are load-bearing, the clipboard/close ones only need to match the
typedef and be non-null. If the header's `action_cb` omits a `userdata`
parameter, recover the runtime via the app handle (`ghostty_app_userdata`) and
drop the last parameter from `casperGhosttyAction` (update Task 3's test too).

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter CasperGhosttyTests.GhosttyRuntimeTrampolineTests`
Expected: PASS.

- [ ] **Step 5: Build the whole module**

Run: `make build`
Expected: PASS (all callback signatures line up with the header).

- [ ] **Step 6: Commit**

```bash
git add Sources/CasperGhostty/GhosttyRuntime.swift \
    Tests/CasperGhosttyTests/GhosttyRuntimeTrampolineTests.swift
git commit -m "Add GhosttyRuntime wrapping the libghostty app and runtime callbacks"
```

---

### Task 4: `GhosttySurfaceConfiguration` + `GhosttySurface` handle

**Files:**
- Create: `Sources/CasperGhostty/GhosttySurfaceConfiguration.swift`
- Create: `Sources/CasperGhostty/GhosttySurface.swift`
- Test: `Tests/CasperGhosttyTests/GhosttySurfaceConfigurationTests.swift`

**Interfaces:**
- Consumes: `GhosttyRuntime.app`; `GhosttyError`.
- Produces:
  - `struct GhosttySurfaceConfiguration` with:
    `var workingDirectory: String?`, `var command: String?`,
    `var environment: [String: String]`, `var scaleFactor: Double`,
    `var fontSize: Float`, and
    `func withCValue<R>(nsview: UnsafeMutableRawPointer, _ body: (inout ghostty_surface_config_s) -> R) -> R`
    (marshals env vars + strings with correct lifetimes, sets
    `platform_tag = GHOSTTY_PLATFORM_MACOS` and `platform.macos.nsview`).
  - `final class GhosttySurface` (main-thread affine, not `Sendable`):
    - `init(runtime: GhosttyRuntime, configuration: GhosttySurfaceConfiguration, nsview: UnsafeMutableRawPointer) throws`
    - `func setSize(widthPixels: UInt32, heightPixels: UInt32)`
    - `func setContentScale(x: Double, y: Double)`
    - `func setFocus(_ focused: Bool)`
    - `func draw()`
    - input: `func sendText(_:)`, `func sendKey(_:)`,
      `func sendMouseButton(state:button:mods:)`,
      `func sendMousePos(x:y:mods:)`, `func sendMouseScroll(deltaX:deltaY:mods:)`
    - `deinit` → `ghostty_surface_free`.

**⚠ confirm against `Vendor/ghostty/ghostty.h`:** the `ghostty_surface_config_s` field
set at v1.3.1 (`platform_tag`, `platform.macos.nsview`, `userdata`,
`scale_factor`, `font_size`, `working_directory`, `command`, `env_vars`,
`env_var_count`, plus any others — some fields shown in the research were from
`main`), the `ghostty_env_var_s { const char* key; const char* value; }` shape,
and that `ghostty_surface_new(app, &config)` returns `ghostty_surface_t?`.

- [ ] **Step 1: Write the failing marshaling test**

`Tests/CasperGhosttyTests/GhosttySurfaceConfigurationTests.swift`:

```swift
import XCTest
import GhosttyKit
@testable import CasperGhostty

final class GhosttySurfaceConfigurationTests: XCTestCase {
    func testMarshalsDirectoryAndEnv() {
        var config = GhosttySurfaceConfiguration()
        config.workingDirectory = "/tmp/wt"
        config.environment = ["CASPER_PORT": "40000"]
        config.scaleFactor = 2.0

        // A throwaway non-null pointer stands in for the NSView.
        var sentinel = 0
        withUnsafeMutablePointer(to: &sentinel) { raw in
            let nsview = UnsafeMutableRawPointer(raw)
            config.withCValue(nsview: nsview) { c in
                XCTAssertEqual(c.platform_tag, GHOSTTY_PLATFORM_MACOS)
                XCTAssertEqual(c.platform.macos.nsview, nsview)
                XCTAssertEqual(c.scale_factor, 2.0)
                XCTAssertEqual(String(cString: c.working_directory), "/tmp/wt")
                XCTAssertEqual(c.env_var_count, 1)
                XCTAssertEqual(String(cString: c.env_vars.pointee.key), "CASPER_PORT")
                XCTAssertEqual(String(cString: c.env_vars.pointee.value), "40000")
            }
        }
    }

    func testNilDirectoryLeavesNullPointer() {
        let config = GhosttySurfaceConfiguration()
        var sentinel = 0
        withUnsafeMutablePointer(to: &sentinel) { raw in
            config.withCValue(nsview: UnsafeMutableRawPointer(raw)) { c in
                XCTAssertNil(c.working_directory)
                XCTAssertEqual(c.env_var_count, 0)
            }
        }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter CasperGhosttyTests.GhosttySurfaceConfigurationTests`
Expected: FAIL — `GhosttySurfaceConfiguration` undefined.

- [ ] **Step 3: Implement the configuration**

`Sources/CasperGhostty/GhosttySurfaceConfiguration.swift` (the nested
`withCString`/array marshaling keeps every C string alive for the `body` call —
the same discipline `CasperGit` uses for `git_strarray`):

```swift
import GhosttyKit

/// Swift-native description of a terminal surface, marshaled into a
/// `ghostty_surface_config_s` for `ghostty_surface_new`. Strings and the env
/// array are only valid inside `withCValue`'s `body` (they live on the stack).
public struct GhosttySurfaceConfiguration {
    public var workingDirectory: String?
    public var command: String?
    public var environment: [String: String]
    public var scaleFactor: Double
    public var fontSize: Float

    public init(
        workingDirectory: String? = nil,
        command: String? = nil,
        environment: [String: String] = [:],
        scaleFactor: Double = 1.0,
        fontSize: Float = 0  // 0 → libghostty default
    ) {
        self.workingDirectory = workingDirectory
        self.command = command
        self.environment = environment
        self.scaleFactor = scaleFactor
        self.fontSize = fontSize
    }

    /// Build a `ghostty_surface_config_s` valid for the duration of `body`.
    public func withCValue<R>(
        nsview: UnsafeMutableRawPointer,
        _ body: (inout ghostty_surface_config_s) -> R
    ) -> R {
        var c = ghostty_surface_config_s()
        c.platform_tag = GHOSTTY_PLATFORM_MACOS
        c.platform.macos.nsview = nsview
        c.userdata = nil
        c.scale_factor = scaleFactor
        c.font_size = fontSize

        // Flatten the env dict into parallel C-string storage, then an array of
        // ghostty_env_var_s pointing into it.
        let pairs = environment.map { ($0.key, $0.value) }
        return withCStrings(pairs.map { $0.0 }) { keys in
            withCStrings(pairs.map { $0.1 }) { values in
                var envVars = [ghostty_env_var_s]()
                envVars.reserveCapacity(pairs.count)
                for i in pairs.indices {
                    envVars.append(ghostty_env_var_s(key: keys[i], value: values[i]))
                }
                return withOptionalCString(workingDirectory) { wd in
                    withOptionalCString(command) { cmd in
                        c.working_directory = wd
                        c.command = cmd
                        return envVars.withUnsafeMutableBufferPointer { buf in
                            c.env_vars = buf.baseAddress
                            c.env_var_count = buf.count
                            return body(&c)
                        }
                    }
                }
            }
        }
    }
}

/// Call `body` with an array of C strings valid for its duration.
private func withCStrings<R>(
    _ strings: [String], _ body: ([UnsafePointer<CChar>]) -> R
) -> R {
    func recurse(_ index: Int, _ acc: [UnsafePointer<CChar>]) -> R {
        if index == strings.count { return body(acc) }
        return strings[index].withCString { ptr in
            recurse(index + 1, acc + [ptr])
        }
    }
    return recurse(0, [])
}

private func withOptionalCString<R>(
    _ string: String?, _ body: (UnsafePointer<CChar>?) -> R
) -> R {
    guard let string else { return body(nil) }
    return string.withCString { body($0) }
}
```

- [ ] **Step 4: Run the marshaling test to verify it passes**

Run: `swift test --filter CasperGhosttyTests.GhosttySurfaceConfigurationTests`
Expected: PASS.

- [ ] **Step 5: Implement `GhosttySurface`**

`Sources/CasperGhostty/GhosttySurface.swift` (no unit test — every method calls
into a live surface; covered by the Task 7 manual checklist):

```swift
import GhosttyKit

/// Owns a libghostty `ghostty_surface_t` and frees it on deinit (same ownership
/// pattern as `CasperGit.Repository`). Main-thread affine; not `Sendable`.
public final class GhosttySurface {
    let surface: ghostty_surface_t

    /// Create a surface hosted in `nsview`. Throws if libghostty returns null.
    public init(
        runtime: GhosttyRuntime,
        configuration: GhosttySurfaceConfiguration,
        nsview: UnsafeMutableRawPointer
    ) throws {
        guard let app = runtime.app else {
            throw GhosttyError(reason: "runtime has no app")
        }
        let created = configuration.withCValue(nsview: nsview) { c in
            ghostty_surface_new(app, &c)
        }
        guard let created else {
            throw GhosttyError(reason: "ghostty_surface_new returned null")
        }
        self.surface = created
    }

    deinit { ghostty_surface_free(surface) }

    /// Set the drawable size in *pixels* (backing-store units).
    public func setSize(widthPixels: UInt32, heightPixels: UInt32) {
        ghostty_surface_set_size(surface, widthPixels, heightPixels)
    }

    public func setContentScale(x: Double, y: Double) {
        ghostty_surface_set_content_scale(surface, x, y)
    }

    public func setFocus(_ focused: Bool) {
        ghostty_surface_set_focus(surface, focused)
    }

    public func draw() { ghostty_surface_draw(surface) }

    /// Committed/IME text (from `NSTextInputClient.insertText`).
    public func sendText(_ text: String) {
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(strlen(ptr)))
        }
    }

    @discardableResult
    public func sendKey(_ event: ghostty_input_key_s) -> Bool {
        ghostty_surface_key(surface, event)
    }

    public func sendMouseButton(
        state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e,
        mods: ghostty_input_mods_e
    ) {
        _ = ghostty_surface_mouse_button(surface, state, button, mods)
    }

    public func sendMousePos(x: Double, y: Double, mods: ghostty_input_mods_e) {
        ghostty_surface_mouse_pos(surface, x, y, mods)
    }

    public func sendMouseScroll(
        deltaX: Double, deltaY: Double, mods: ghostty_input_scroll_mods_t
    ) {
        ghostty_surface_mouse_scroll(surface, deltaX, deltaY, mods)
    }
}
```

**⚠ confirm** each `ghostty_surface_*` signature against `Vendor/ghostty/ghostty.h`
(pixel vs point size units, the `mouse_scroll` mods type
`ghostty_input_scroll_mods_t` vs `_e`, and `ghostty_surface_text`'s length type
`uintptr_t`).

- [ ] **Step 6: Build**

Run: `make build`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/CasperGhostty/GhosttySurfaceConfiguration.swift \
    Sources/CasperGhostty/GhosttySurface.swift \
    Tests/CasperGhosttyTests/GhosttySurfaceConfigurationTests.swift
git commit -m "Add GhosttySurface handle and its configuration marshaling"
```

---

### Task 5: `GhosttyInput` mapping + `GhosttySurfaceView` (AppKit host)

**Files:**
- Create: `Sources/CasperGhostty/GhosttyInput.swift`
- Create: `Sources/CasperGhostty/GhosttySurfaceView.swift`
- Create: `Sources/CasperGhostty/GhosttySurfaceRepresentable.swift`
- Test: `Tests/CasperGhosttyTests/GhosttyInputTests.swift`

**Interfaces:**
- Consumes: `GhosttySurface`, `GhosttyRuntime`, `GhosttySurfaceConfiguration`.
- Produces:
  - `func ghosttyMods(from flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e`
    (pure, tested).
  - `func ghosttyKeyEvent(_ event: NSEvent, action: ghostty_input_action_e) -> ghostty_input_key_s`
    (builds the key struct; used by the view).
  - `final class GhosttySurfaceView: NSView, NSTextInputClient` — creates its
    `GhosttySurface` once it has a window, forwards events, pushes size/scale,
    tracks focus. `init(runtime:configuration:)`.
  - `struct GhosttySurfaceRepresentable: NSViewRepresentable` — SwiftUI wrapper
    (for Plan 5).

**⚠ confirm against `Vendor/ghostty/ghostty.h`:** the `ghostty_input_mods_e` bit
constants (`GHOSTTY_MODS_SHIFT`, `_CTRL`, `_ALT`, `_SUPER`), the
`ghostty_input_key_s` field set (`action`, `mods`, `consumed_mods`, `keycode`,
`text`, `unshifted_codepoint`, `composing`), and `ghostty_input_action_e`
members (`GHOSTTY_ACTION_PRESS/RELEASE/REPEAT`).

- [ ] **Step 1: Write the failing modifier-mapping test**

`Tests/CasperGhosttyTests/GhosttyInputTests.swift`:

```swift
import XCTest
import AppKit
import GhosttyKit
@testable import CasperGhostty

final class GhosttyInputTests: XCTestCase {
    func testNoModifiersIsEmpty() {
        XCTAssertEqual(ghosttyMods(from: []).rawValue, GHOSTTY_MODS_NONE.rawValue)
    }

    func testCommandShiftMapsToSuperShift() {
        let mods = ghosttyMods(from: [.command, .shift])
        XCTAssertNotEqual(mods.rawValue & GHOSTTY_MODS_SUPER.rawValue, 0)
        XCTAssertNotEqual(mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue, 0)
        XCTAssertEqual(mods.rawValue & GHOSTTY_MODS_CTRL.rawValue, 0)
    }

    func testControlOptionMapsToCtrlAlt() {
        let mods = ghosttyMods(from: [.control, .option])
        XCTAssertNotEqual(mods.rawValue & GHOSTTY_MODS_CTRL.rawValue, 0)
        XCTAssertNotEqual(mods.rawValue & GHOSTTY_MODS_ALT.rawValue, 0)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter CasperGhosttyTests.GhosttyInputTests`
Expected: FAIL — `ghosttyMods` undefined.

- [ ] **Step 3: Implement the input mapping**

`Sources/CasperGhostty/GhosttyInput.swift`:

```swift
import AppKit
import GhosttyKit

/// Map Cocoa modifier flags to libghostty's modifier bitset.
public func ghosttyMods(from flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    var raw = GHOSTTY_MODS_NONE.rawValue
    if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
    if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
    if flags.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
    if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
    return ghostty_input_mods_e(raw)
}

/// Build a libghostty key event from an NSEvent. `text` points into the event's
/// `characters`, valid for the synchronous `ghostty_surface_key` call.
public func ghosttyKeyEvent(
    _ event: NSEvent, action: ghostty_input_action_e
) -> ghostty_input_key_s {
    var key = ghostty_input_key_s()
    key.action = action
    key.mods = ghosttyMods(from: event.modifierFlags)
    key.consumed_mods = ghostty_input_mods_e(GHOSTTY_MODS_NONE.rawValue)
    key.keycode = UInt32(event.keyCode)
    key.composing = false
    key.text = nil  // committed text is delivered separately via insertText
    key.unshifted_codepoint = 0
    return key
}
```

- [ ] **Step 4: Run the mapping test to verify it passes**

Run: `swift test --filter CasperGhosttyTests.GhosttyInputTests`
Expected: PASS.

- [ ] **Step 5: Implement the AppKit host view**

`Sources/CasperGhostty/GhosttySurfaceView.swift` (models the Ghostty macOS
`SurfaceView` shape: libghostty owns the Metal layer/render thread — the view
never creates a layer and never calls `draw()` itself; it passes `self` as
`nsview`, forwards events, and pushes size/scale on geometry changes):

```swift
import AppKit
import GhosttyKit

/// An `NSView` that libghostty renders one terminal surface into. Forwards
/// keyboard/mouse/text events and geometry changes to the surface.
public final class GhosttySurfaceView: NSView, NSTextInputClient {
    private let runtime: GhosttyRuntime
    private let configuration: GhosttySurfaceConfiguration
    private var surface: GhosttySurface?

    public init(runtime: GhosttyRuntime, configuration: GhosttySurfaceConfiguration) {
        self.runtime = runtime
        self.configuration = configuration
        super.init(frame: .zero)
        // libghostty attaches its own CAMetalLayer to this view.
        wantsLayer = true
        postsFrameChangedNotifications = true
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    public override var acceptsFirstResponder: Bool { true }

    // Create the surface once the view is in a window (so `self` is a valid,
    // sized host). Idempotent.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard surface == nil, window != nil else { return }
        let nsview = Unmanaged.passUnretained(self).toOpaque()
        do {
            surface = try GhosttySurface(
                runtime: runtime, configuration: configuration, nsview: nsview)
            pushContentScale()
            pushSize()
        } catch {
            NSLog("Casper: surface creation failed: \(error)")
        }
    }

    // MARK: Geometry

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        pushSize()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        pushContentScale()
        pushSize()
        if let screen = window?.screen {
            // Drive libghostty's internal display link at the right refresh rate.
            let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            if let id = number?.uint32Value {
                ghostty_surface_set_display_id(surface?.surface ?? nil, id)
            }
        }
    }

    private func pushSize() {
        guard let surface else { return }
        let backing = convertToBacking(bounds).size
        surface.setSize(
            widthPixels: UInt32(max(0, backing.width)),
            heightPixels: UInt32(max(0, backing.height)))
    }

    private func pushContentScale() {
        guard let surface else { return }
        let backing = convertToBacking(NSSize(width: 1, height: 1))
        surface.setContentScale(x: Double(backing.width), y: Double(backing.height))
    }

    // MARK: Focus

    public override func becomeFirstResponder() -> Bool {
        surface?.setFocus(true)
        return super.becomeFirstResponder()
    }

    public override func resignFirstResponder() -> Bool {
        surface?.setFocus(false)
        return super.resignFirstResponder()
    }

    // MARK: Keyboard

    public override func keyDown(with event: NSEvent) {
        guard let surface else { return }
        _ = surface.sendKey(ghosttyKeyEvent(event, action: GHOSTTY_ACTION_PRESS))
        // Let the input system produce committed text → insertText(_:).
        interpretKeyEvents([event])
    }

    public override func keyUp(with event: NSEvent) {
        surface?.sendKey(ghosttyKeyEvent(event, action: GHOSTTY_ACTION_RELEASE))
    }

    public override func flagsChanged(with event: NSEvent) {
        surface?.sendKey(ghosttyKeyEvent(event, action: GHOSTTY_ACTION_PRESS))
    }

    // MARK: Mouse

    public override func mouseDown(with event: NSEvent) { mouseButton(event, .left, down: true) }
    public override func mouseUp(with event: NSEvent) { mouseButton(event, .left, down: false) }
    public override func rightMouseDown(with event: NSEvent) { mouseButton(event, .right, down: true) }
    public override func rightMouseUp(with event: NSEvent) { mouseButton(event, .right, down: false) }
    public override func mouseMoved(with event: NSEvent) { mousePos(event) }
    public override func mouseDragged(with event: NSEvent) { mousePos(event) }

    public override func scrollWheel(with event: NSEvent) {
        surface?.sendMouseScroll(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            mods: ghostty_input_scroll_mods_t(0))  // ⚠ confirm precision/momentum bits
    }

    private enum Btn { case left, right }

    private func mouseButton(_ event: NSEvent, _ btn: Btn, down: Bool) {
        guard let surface else { return }
        let state = down ? GHOSTTY_MOUSE_PRESS : GHOSTTY_MOUSE_RELEASE
        let button = btn == .left ? GHOSTTY_MOUSE_LEFT : GHOSTTY_MOUSE_RIGHT
        surface.sendMouseButton(
            state: state, button: button, mods: ghosttyMods(from: event.modifierFlags))
    }

    private func mousePos(_ event: NSEvent) {
        guard let surface else { return }
        let p = convert(event.locationInWindow, from: nil)
        // libghostty expects top-left origin; flip Y.
        surface.sendMousePos(
            x: Double(p.x), y: Double(bounds.height - p.y),
            mods: ghosttyMods(from: event.modifierFlags))
    }

    // MARK: NSTextInputClient (committed/IME text)

    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        surface?.sendText(text)
    }

    public func hasMarkedText() -> Bool { false }
    public func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    public func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    public func setMarkedText(_ s: Any, selectedRange: NSRange, replacementRange: NSRange) {}
    public func unmarkText() {}
    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    public func attributedSubstring(
        forProposedRange range: NSRange, actualRange: NSRangePointer?
    ) -> NSAttributedString? { nil }
    public func characterIndex(for point: NSPoint) -> Int { NSNotFound }
    public func firstRect(
        forCharacterRange range: NSRange, actualRange: NSRangePointer?
    ) -> NSRect { .zero }
    public func doCommand(by selector: Selector) {}
}
```

**⚠ confirm** the mouse enum constants (`GHOSTTY_MOUSE_PRESS/RELEASE`,
`GHOSTTY_MOUSE_LEFT/RIGHT`), `ghostty_surface_set_display_id`'s existence/
signature, and the scroll mods type against `Vendor/ghostty/ghostty.h`.

- [ ] **Step 6: Implement the SwiftUI bridge**

`Sources/CasperGhostty/GhosttySurfaceRepresentable.swift`:

```swift
import SwiftUI

/// SwiftUI wrapper hosting a `GhosttySurfaceView`. Consumed by CasperUI (Plan 5).
public struct GhosttySurfaceRepresentable: NSViewRepresentable {
    private let runtime: GhosttyRuntime
    private let configuration: GhosttySurfaceConfiguration

    public init(runtime: GhosttyRuntime, configuration: GhosttySurfaceConfiguration) {
        self.runtime = runtime
        self.configuration = configuration
    }

    public func makeNSView(context: Context) -> GhosttySurfaceView {
        GhosttySurfaceView(runtime: runtime, configuration: configuration)
    }

    public func updateNSView(_ nsView: GhosttySurfaceView, context: Context) {}
}
```

- [ ] **Step 7: Build**

Run: `make build`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/CasperGhostty/GhosttyInput.swift \
    Sources/CasperGhostty/GhosttySurfaceView.swift \
    Sources/CasperGhostty/GhosttySurfaceRepresentable.swift \
    Tests/CasperGhosttyTests/GhosttyInputTests.swift
git commit -m "Host a libghostty surface in an AppKit NSView with input forwarding"
```

---

### Task 6: `GhosttyDemo` + wire `casper` GUI mode

**Files:**
- Create: `Sources/CasperGhostty/GhosttyDemo.swift`
- Modify: `Sources/casper/main.swift`

**Interfaces:**
- Consumes: `GhosttyRuntime`, `GhosttySurfaceConfiguration`, `GhosttySurfaceView`.
- Produces: `enum GhosttyDemo { public static func run(directory: String) -> Never }`.

- [ ] **Step 1: Implement the demo window**

`Sources/CasperGhostty/GhosttyDemo.swift`:

```swift
import AppKit

/// Minimal end-to-end harness: a single window hosting one live terminal
/// surface. This is Plan 4's deliverable and the manual-test entry point; Plan 5
/// replaces it with the real Casper app. Runs the AppKit loop and never returns.
public enum GhosttyDemo {
    public static func run(directory: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        let delegate = DemoDelegate(directory: directory)
        app.delegate = delegate
        app.activate(ignoringOtherApps: true)
        app.run()
        // NSApplication.run does not return.
        fatalError("unreachable")
    }
}

private final class DemoDelegate: NSObject, NSApplicationDelegate {
    private let directory: String
    private var window: NSWindow?
    private var runtime: GhosttyRuntime?

    init(directory: String) { self.directory = directory }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let runtime = try GhosttyRuntime()
            runtime.onAction = { action in
                if case .setTitle(let title) = action {
                    // Reflect the shell's title in the window.
                    NSApp.windows.first?.title = title
                }
            }
            self.runtime = runtime

            var config = GhosttySurfaceConfiguration()
            config.workingDirectory = directory

            let view = GhosttySurfaceView(runtime: runtime, configuration: config)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false)
            window.title = "Casper — GhosttyKit demo"
            window.contentView = view
            window.center()
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            self.window = window
        } catch {
            NSLog("Casper demo failed: \(error)")
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
```

- [ ] **Step 2: Wire GUI mode in `main.swift`**

Replace the `.gui` branch in `Sources/casper/main.swift`. The new file:

```swift
import CasperCLI
import CasperGhostty
import Foundation

// Single-binary fork: empty argv launches the GUI; any subcommand runs the CLI.
// Plan 4 GUI mode opens a minimal one-terminal demo window (Plan 5 replaces it
// with the real Casper app).
switch LaunchMode.detect(arguments: CommandLine.arguments) {
case .gui:
    GhosttyDemo.run(directory: FileManager.default.currentDirectoryPath)
case .cli:
    CasperCommand.main()
}
```

- [ ] **Step 3: Build**

Run: `make build`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/CasperGhostty/GhosttyDemo.swift Sources/casper/main.swift
git commit -m "Launch a one-terminal Ghostty demo window in casper GUI mode"
```

---

### Task 7: Manual verification checklist + docs + memory

**Files:**
- Modify: `README.md` (add a "Running the terminal (Plan 4)" note)
- Modify: `.claude/project-memory/references/project.md` (status → Plan 4)
- Create: `.claude/project-memory/references/ghosttykit-pin.md` (the pin)
- Modify: `.claude/project-memory/MEMORY.md` (index the new note)

**Interfaces:** none (verification + documentation).

- [ ] **Step 1: Run the full automated suite**

Run: `make test`
Expected: all prior tests plus the new `CasperGhosttyTests` PASS (target ~96+
tests total; the previous baseline was 92).

- [ ] **Step 2: Manual terminal checklist (design §13 — cannot be automated)**

Run: `make build && ./.build/debug/casper`
Confirm each, checking the box only after observing it:
- [ ] A window titled "Casper — GhosttyKit demo" opens with a rendered shell
      prompt (GPU-accelerated text, correct font).
- [ ] Typing `ls` + Return runs the command; output renders.
- [ ] The shell's working directory is the directory `casper` was launched from.
- [ ] Resizing the window reflows the terminal (columns/rows update).
- [ ] Focus works: keystrokes only go to the terminal when the window is key.
- [ ] The window title updates when you run e.g. `cd /tmp` (PWD/title action).
- [ ] Quitting the app (Cmd-Q / closing the window) exits cleanly, no crash.

If any item fails, use `superpowers:systematic-debugging`; likely culprits are a
callback-signature mismatch vs `Vendor/ghostty/ghostty.h` (Task 3/4) or the size/scale
push (Task 5).

- [ ] **Step 3: Update the README**

Add under the build/run section:

```markdown
### Running the terminal (Plan 4)

`casper` with no arguments opens a minimal window with one live terminal
surface (libghostty via GhosttyKit) rooted at the current directory. This is the
Plan 4 deliverable; the full app (sidebar, worktrees, splits) arrives in Plan 5.
```

- [ ] **Step 4: Record the GhosttyKit pin in project memory**

Use the `skillbox:project-memory` skill to create
`.claude/project-memory/references/ghosttykit-pin.md` (type `reference`) capturing
verbatim: package `Lakr233/libghostty-spm` `exact: 1.2.8`; asset URL + checksum
`eab8ecf0…`; upstream Ghostty `v1.3.1` / SHA `332b2aef…` (+ Lakr233 patches);
header source of truth = v1.3.1 (NOT `main`, which renumbers the action enum);
consume only the `GhosttyKit` product; linker `c++` + `Carbon`; and the trust
caveat (opaque third-party binary — re-verify the checksum on any bump and diff
the xcframework's bundled `ghostty.h` against upstream v1.3.1). Add the one-line
pointer to `MEMORY.md`.

- [ ] **Step 5: Update the project status note**

Edit `.claude/project-memory/references/project.md`: mark Plan 4 complete
(CasperGhostty module: `GhosttyRuntime`, `GhosttySurface`, AppKit host view,
SwiftUI bridge, one-terminal demo in GUI mode), note the deferred splits/tabs
layout (Plan 5) and the clipboard-paste polish (Plan 5), and set the next
milestone to Plan 5 — CasperUI. Link `[[ghosttykit-pin]]`.

- [ ] **Step 6: Commit**

```bash
git add README.md .claude/project-memory/
git commit -m "Document Plan 4 completion, manual checklist, and the GhosttyKit pin"
```

---

## Self-Review

**Spec coverage (design §3.2, §3.1, §12):**
- CasperGhostty module owning surface lifecycle + the unstable API → Tasks 1–5. ✓
- In-process surface/PTY → `ghostty_surface_new` hosts the PTY in-process. ✓
- API isolation (one module, pinned version, a bump touches one module) → Global
  Constraints + Task 1 pin. ✓
- Splits/tabs → **explicitly deferred to Plan 5** (Scope Boundary); actions are
  still decoded (Task 2) so Plan 5 can act. ✓ (documented deviation, not a gap.)
- Persistence/session/browser/diff/sidebar → not this plan (Plans 5+). ✓

**Placeholder scan:** no "TBD"/"add error handling"/"similar to Task N". The
`⚠ confirm` notes are header-verification steps against the in-repo
`Vendor/ghostty/ghostty.h` (Task 1), not missing content — every step shows real code.

**Type consistency:** `GhosttyRuntime.app` (used by `GhosttySurface` Task 4),
`GhosttyAction.decode` (Task 2 → used in Task 3 trampoline), `GhosttyError`
(Task 1 → thrown in Tasks 3–4), `ghosttyMods`/`ghosttyKeyEvent` (Task 5 →
used in the view), `GhosttySurfaceConfiguration.withCValue` (Task 4 → used by
`GhosttySurface` and the view) — names are consistent across tasks.

**Known risk carried into execution:** the C API is unstable and this plan was
authored without a compiler. The first task pins + vendors the exact header so
every later task reconciles against ground truth; the `⚠ confirm` spots are the
predicted reconciliation points. Treat a signature mismatch as expected
mechanical fix-up, not a design failure.
