# Close Inspector (`browser close` / `diff close`) — Design

**Date:** 2026-07-07
**Status:** Approved (pending written-spec review)
**Scope:** Add `casper browser close` and `casper diff close` CLI subcommands
that collapse the shared inspector panel, mirroring the existing
`casper browser open <url>` / `casper diff open [<file>]` commands.

## Problem

`casper` can open the browser or diff view (`BrowserCommand.Open`,
`DiffCommand.Open`) but has no way to close either from the CLI. Both views
live in the same shared `InspectorState` (`Models.swift:154-176`): one
`collapsed: Bool` flag and one `tab: InspectorTab` (`.browser`/`.diff`).
There is no independent "browser panel" or "diff panel" to close — closing
either view means collapsing the single inspector, but only when that view is
the one currently showing.

## Goals

- `casper browser close [--workspace <id>]` collapses the inspector **only
  if** its active tab is `.browser`.
- `casper diff close [--workspace <id>]` collapses the inspector **only if**
  its active tab is `.diff`.
- If the other tab is active (or the inspector is already collapsed), the
  command is a silent no-op: it still returns success, since the outcome the
  caller wants ("this view is not showing") already holds.
- `--workspace` behaves exactly like every other CLI command: `WorkspaceTargetOption`,
  resolved via `requireSelector`, no new flag semantics.

## Non-Goals

- No change to the browser's loaded URL or the diff's scroll target — closing
  never clears `inspector.browser`'s `Surface` or `diffScrollTarget`. Reopening
  later restores the same content.
- No generic `casper inspector close`. Each subcommand stays scoped to the
  view it names, per the existing `browser`/`diff` command split.

## Design

### Protocol — `ControlProtocol.swift`

Add two `Verb` cases next to the existing `browserOpen`/`diffOpen`
(`ControlProtocol.swift:14-15`):

```swift
case browserClose
case diffClose
```

No new payload fields — both reuse the existing `workspace` selector field
only.

### App dispatch — `ControlServer.swift`

Add two cases in the workspace-scoped `switch` (next to `.browserOpen`/`.diffOpen`,
`ControlServer.swift:80-90`):

```swift
case .browserClose:
    return model.controlCloseBrowser(in: id)
        ? .success(workspace: id.uuidString) : .failure("cannot close browser")
case .diffClose:
    return model.controlCloseDiff(in: id)
        ? .success(workspace: id.uuidString) : .failure("cannot close diff")
```

`controlClose{Browser,Diff}` only return `false` when the workspace itself
can't be located (mirroring `controlOpenBrowser`'s existing `Bool` return) —
the "wrong tab active" case is a no-op success, not a failure.

### App model — `AppModel.swift`

Add two methods next to `controlOpenBrowser`/`controlOpenDiff`
(`AppModel.swift:1328-1368`):

```swift
/// Collapse the inspector if `workspaceID`'s active tab is `.browser`.
/// No-op (still succeeds) if the diff tab is active or the panel is
/// already collapsed — the caller's goal ("browser not showing") already holds.
@discardableResult
func controlCloseBrowser(in workspaceID: UUID) -> Bool {
    guard let ws = workspace(id: workspaceID) else { return false }
    if ws.inspector.tab == .browser {
        setInspectorCollapsed(true, for: workspaceID)
    }
    return true
}

/// Collapse the inspector if `workspaceID`'s active tab is `.diff`. Mirrors
/// `controlCloseBrowser`.
@discardableResult
func controlCloseDiff(in workspaceID: UUID) -> Bool {
    guard let ws = workspace(id: workspaceID) else { return false }
    if ws.inspector.tab == .diff {
        setInspectorCollapsed(true, for: workspaceID)
    }
    return true
}
```

### CLI — `BrowserCommand.swift` / `DiffCommand.swift`

Add a `Close` subcommand to each, following `TerminalCommand.Close`'s shape
(no positional argument here — only the shared workspace target):

```swift
struct Close: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Collapse the browser panel if it is showing.")
    @OptionGroup var target: WorkspaceTargetOption

    func makeCommand() throws -> ControlCommand {
        ControlCommand(verb: .browserClose, workspace: try requireSelector(target))
    }

    func run() throws {
        let response = try sendControl(makeCommand(), retriable: false)
        emit(WorkspaceRefOut(workspace: response.workspace ?? ""))
    }
}
```

(`diff close` is identical with `verb: .diffClose`.) Both register in each
command's `subcommands:` list alongside `Open.self`. `retriable: false`,
matching every other mutating command in this file (`browserOpen`, `diffOpen`,
`terminalClose`) — only pure reads (`workspaceList`, `terminalList`) use `true`.

Output reuses `WorkspaceRefOut` (same as `open`) — no new output struct needed,
since there's no id to echo back.

## Testing

- `ControlCommandTests`: `testBrowserCloseBuildsCommand` /
  `testDiffCloseBuildsCommand`, mirroring `testTerminalCloseBuildsCommand`.
- `ControlHandlerTests` (or `AppModel` tests): verify `controlCloseBrowser`
  collapses when `tab == .browser` and no-ops (returns `true`, `collapsed`
  unchanged-or-already-true) when `tab == .diff`; mirror for
  `controlCloseDiff`.
- Manual verification via `make dev`: `casper browser open <url>` then
  `casper browser close` collapses the inspector; `casper diff close` right
  after is a no-op (inspector stays collapsed, command still exits 0).
