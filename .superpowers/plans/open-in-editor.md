# Open in Editor — Design

**Date:** 2026-07-09 **Status:** Shipped **Scope:** Add a title-bar split-button
to `WorkspaceDetailView`'s toolbar that launches the current workspace's
worktree in an external code editor (VS Code, IntelliJ IDEA, or Xcode),
detecting which of the three are actually usable on the machine.

## Problem

Casper has no way to jump from a workspace into a full IDE on its worktree.
Users currently have to switch to Finder/Terminal and run `code .` / `idea .` /
`xed .` themselves. The toolbar already exposes workspace-scoped actions (diff
badge, inspector toggle) in the same title bar — "open in editor" is a natural
fourth.

## Goals

- A single toolbar control, right-aligned, immediately left of the inspector
  toggle, that opens the current workspace's `worktreePath` in VS Code, IntelliJ
  IDEA, or Xcode.
- Only offer editors that are actually launchable: the CLI shim (`code` / `idea`
  / `xed`) must be on `PATH` *and* the app bundle must resolve via its known
  bundle identifier (needed to show a real icon). Both checks run once at app
  startup; an editor failing either check is omitted from the control entirely.
- One-click quick launch: the button remembers the last editor used **per
  workspace** and launches it directly; a chevron opens a dropdown to launch a
  different (detected) editor, which becomes the new per-workspace default.
- If nothing is detected, the whole control is hidden — no dead button.
- A launch failure (shim vanished since startup, `Process` spawn error) shows a
  native alert; it must never fail silently.

## Non-Goals

- No preference UI for reordering/disabling editors — priority order is fixed:
  VS Code > IntelliJ IDEA > Xcode.
- No live re-detection while Casper is running (e.g. after installing an editor
  mid-session) — detection is startup-only, matching how `resolveGitBacking()`
  already runs once in `AppModel.init` (`AppModel.swift:264`).
- No bundling of third-party editor icon assets — icons come from `NSWorkspace`
  at runtime, not from Casper's own asset catalog.

## Design

### `EditorKind` — `Sources/CasperCore/Models.swift`

A new `Codable`, `CaseIterable` enum, pure Swift (no AppKit), so it can live in
CasperCore and be stored directly on `Workspace`:

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

### `Workspace.lastUsedEditor` — `Sources/CasperCore/Models.swift`

Add one field next to `inspector` (`Models.swift:236`), following the exact
legacy-decode pattern already used for `inspector` (`Models.swift:319-320`) so
pre-existing `session.json` files load cleanly:

```swift
public var inspector: InspectorState
public var lastUsedEditor: EditorKind?
```

- `init(...)`: new parameter `lastUsedEditor: EditorKind? = nil`.
- `CodingKeys` (`Models.swift:273-277`): add `case lastUsedEditor`.
- `encode(to:)` (`Models.swift:283-296`):
  `try c.encodeIfPresent(lastUsedEditor, forKey: .lastUsedEditor)`.
- `init(from:)` (`Models.swift:305-321`): `self.lastUsedEditor = try container.decodeIfPresent(EditorKind.self, forKey: .lastUsedEditor)`
  (defaults to `nil` — no legacy file has ever had a value here, unlike
  `inspector`, so no `??` fallback is needed).

### `EditorLauncher` — new file `Sources/CasperUI/EditorLauncher.swift`

Detection and launching both need `NSWorkspace`, so this lives in CasperUI (the
module that already owns AppKit bridges), as a stateless namespace — mirrors how
`AppModel` already imports `AppKit` directly (`AppModel.swift:1`):

```swift
enum EditorLauncher {
    /// Editors whose CLI shim resolves on `PATH` *and* whose app bundle
    /// resolves via its bundle identifier. Both must hold — the icon lookup
    /// needs the bundle, and the launch needs the shim — so an editor with
    /// only one of the two is omitted rather than shown half-working.
    static func detectInstalled() -> [EditorKind] {
        EditorKind.priorityOrder.filter { kind in
            resolveCLIPath(kind.cliCommand) != nil && resolveBundleURL(kind) != nil
        }
    }

    static func icon(for kind: EditorKind) -> NSImage? {
        resolveBundleURL(kind).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    /// Launches `kind`'s CLI shim with `path` as its sole argument, run in
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

Runs once at startup, three short-lived shell processes total (one per
`EditorKind`) — not on every menu open.

### `AppModel` wiring — `Sources/CasperUI/AppModel.swift`

- New `private(set) var availableEditors: [EditorKind]`, computed once in `init`
  right after `resolveGitBacking()` (`AppModel.swift:264`):
  `self.availableEditors = EditorLauncher.detectInstalled()`.
- New `var editorLaunchError: String?` (`@Observable`, drives a `.alert` in
  `WorkspaceDetailView`).
- New mutator, alongside `setInspectorTab`/`setInspectorCollapsed`
  (`AppModel.swift:985-997`), following the same `locate(workspaceID)` +
  `persist()` shape:

```swift
/// Resolves which editor a click should launch: an explicit `kind` (from
/// picking a dropdown row) wins, else the workspace's remembered default,
/// else the first detected editor. Pure and side-effect-free so it is
/// unit-testable without touching `EditorLauncher`/`Process`.
func resolvedEditor(_ kind: EditorKind?, for workspace: Workspace) -> EditorKind? {
    kind ?? workspace.lastUsedEditor ?? availableEditors.first
}

/// Launches `kind` (or the workspace's remembered/default editor when nil)
/// on the workspace's worktree, and remembers it as this workspace's
/// default for next time.
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

### Toolbar — `Sources/CasperUI/WorkspaceDetailView.swift`

New `ToolbarItem(placement: .primaryAction)` inserted before `inspectorItem`
(`WorkspaceDetailView.swift:76-90`) so it lands to its left:

```swift
if !model.availableEditors.isEmpty {
    ToolbarItem(placement: .primaryAction) { editorButton }
}
let inspectorItem = ToolbarItem(placement: .primaryAction) { inspectorToggle }
...
```

`editorButton`, next to `inspectorToggle` (`WorkspaceDetailView.swift:203-210`),
uses SwiftUI's native split-button `Menu(primaryAction:)` so the main tap and
the chevron are two independent targets for free:

```swift
private var editorButton: some View {
    let current = workspace.lastUsedEditor ?? model.availableEditors.first
    return Menu {
        ForEach(model.availableEditors, id: \.self) { kind in
            Button {
                model.openInEditor(kind, for: workspace.id)
            } label: {
                if let icon = EditorLauncher.icon(for: kind) {
                    Label { Text(kind.displayName) } icon: { Image(nsImage: icon) }
                } else {
                    Text(kind.displayName)
                }
            }
        }
    } label: {
        if let current, let icon = EditorLauncher.icon(for: current) {
            Label { Text(current.displayName) } icon: { Image(nsImage: icon) }
        } else {
            Text(current?.displayName ?? "Editor")
        }
    } primaryAction: {
        model.openInEditor(nil, for: workspace.id)
    }
    .help("Open in Editor")
}
```

`.alert` for `editorLaunchError` attaches once at the `WorkspaceDetailView` body
level (or hoisted to `RootView` if a shared alert host already exists — confirm
during planning), showing the message and clearing it on dismiss.

## Testing

- **Unit (XCTest, CasperCore):** `EditorKind` case/metadata coverage;
  `Workspace` round-trip with `lastUsedEditor` set and `nil`; legacy decode of a
  `session.json` missing the `lastUsedEditor` key (must decode to `nil` without
  failing).
- **Unit (XCTest, CasperUI):** `AppModel.resolvedEditor` — covers the three
  fallback tiers (explicit `kind`, workspace's `lastUsedEditor`, first of
  `availableEditors`) and the `nil` case (no `kind`, no remembered editor, no
  detected editors). This is the only part of the feature that is pure logic
  over in-memory state, so it is the only part covered by an `AppModel` unit
  test — `openInEditor` itself calls `EditorLauncher.launch`, which is not
  mocked (see below), so its persistence/alert side effects are covered by the
  manual pass instead.
- **Manual (`debug-casper` + live click-through):** with VS Code and/or Xcode
  actually installed, confirm the button shows the right icon/name, quick-launch
  opens the worktree, the dropdown lists only detected editors, switching
  editors updates the persisted default across a restart, and an editor
  uninstalled between startup and click surfaces the alert instead of failing
  silently. `EditorLauncher.detectInstalled()`/`launch()` themselves are not
  unit tested — they depend on real installed apps/CLI shims on the test
  machine, consistent with how the project already treats OS-dependent glue (see
  `.superpowers/architecture.md` → Testing strategy).
