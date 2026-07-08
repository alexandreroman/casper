# Casper — Implementation Status

The single, authoritative record of implementation progress. The design source of
truth is [`architecture.md`](architecture.md) plus the per-theme docs in
`themes/`; the documentation map is [`INDEX.md`](INDEX.md); active plans are in `plans/`.

Status legend: ✅ built · ◐ partial · ❌ not started.

## Roadmap at a glance

The build proceeds in five module plans. **All five are implemented.** CasperUI
(Plan 5, the real SwiftUI app) is complete across its five sub-projects: **UI-1**
(app shell + startup wiring), **UI-2** (Space model + Space-grouped sidebar +
linked Git worktrees), **UI-3** (recursive splits/tabs layout), **UI-4** (WKWebView
browser surface), and **UI-5** (read-only diff viewer). The live GUI verification
pass on a real desktop is complete. The v1 agent target is Claude Code only.

| Plan | Module | Status |
| --- | --- | --- |
| 1 | CasperCore | ✅ |
| 2 | CasperGit (+ Clibgit2) | ✅ worktrees/status/`remoteURL`/`git_diff` built |
| 3 | CasperCLI + CasperAgents | ✅ |
| 4 | CasperGhostty | ✅ one terminal + splits/tabs composed by UI-3 |
| 5 | CasperUI + app | ✅ UI-1..UI-5 built (sidebar + worktrees + splits/tabs + browser + diff); live GUI check done |

Two developer-tooling features are built on top (both `#if DEBUG`): the
debug/observability channel and debug surface addressing. The Space (project)
model shipped with UI-2; only **Space rename** remains open for it (the
per-workspace `+/−` diff summary is **dropped** — decision 2026-07-06).

> **Latest work — the tabbed surface model (UI-3) is replaced by a tmux-style
> pane layout** (no tabs, one surface per pane), with close-on-process-exit and a
> shared-NSView collapse fix. See
> [Surface layout — tmux-style panes](#surface-layout--tmux-style-panes-supersedes-ui-3-tabs--) below. UI-3 sections in this file and in `themes/app-ui.md`
> describe the superseded tab model.

## Modules

### CasperCore — ✅
Models (`AgentState`, `Todo`, `LayoutTree`, session), `WorktreeManager`
(create/list/remove/deleteBranch/isClean with `WorktreeError` mapping),
`PortAllocator`, `SessionStore`, and the control-channel protocol + socket
(`ControlProtocol`/`ControlSocket`) plus CLI-targeting/progress helpers.

### CasperGit + Clibgit2 — ✅ (core)
`Repository` (open/discover/init, branch queries, worktree
add/list/lookup/validate/prune, status/isClean, `remoteURL`, `diffWorkdirToHead`),
`Worktree`, `GitError`.
- **`git_diff` is built** — `diffWorkdirToHead()` returns a structured
  `GitDiff` (files → hunks → lines, statuses, binary flag; working tree + index
  vs HEAD, unborn HEAD as additions), unblocking the diff viewer (design §11).
  (Branch-divergence diffs were designed for the Space `+/−` summary, now
  dropped — not built.)
- Standing limitations: `remove` prunes the worktree but not its branch, so
  recreating a same-named workspace surfaces an opaque `.gitFailure` (fix by
  mapping it to a clear reason or deleting the branch on remove); libgit2 is
  unpinned in brew/CI; `WorktreeManager` opens the exact repo root
  (`Repository.open`) rather than `discover`.

### CasperAgents + CasperCLI — ✅
`ClaudeCodeAdapter.surfaceEnvironment` (per-surface env injection); the `casper`
executable with the GUI/CLI fork and the domain CLI
(`status`/`progress`/`notify`/`terminal`/`browser`/`diff`/`workspace`) that emits
JSON over `$CASPER_CONTROL_SOCKET` (errors exit non-zero). There is **no hook
mechanism** — a workspace's agent state is set only by the explicit CLI verbs. See
the `domain-cli-control-channel` memory note for the current surface.
- The bundle executable directory is injected onto each surface's `PATH` (via
  `surfaceEnvironment(casperDirectory:basePath:)`) so `casper` resolves inside
  Casper terminals.

### CasperGhostty — ✅ (one terminal end-to-end)
`GhosttyRuntime`, `GhosttyAction`, `GhosttySurface`, `GhosttySurfaceView`,
`GhosttySurfaceRepresentable`, `GhosttyDemo`, `GhosttyMenu`,
`GhosttyActionDispatcher`. Rendering is display-link driven, so
`GHOSTTY_ACTION_RENDER` needs no explicit `draw()` wiring.
- **Keyboard & clipboard — ✅.** Control/Option/⌘ combos all work (Ctrl-C/D,
  ⌘C/⌘V/⌘A via NSPasteboard, ⌘±/0 font size, ⌘Q, ⌘W); macOS menu bar
  (App/Edit/View/Window); `macos-option-as-alt` wired (inert in the pinned
  binary). ⌘-key/menu paths confirmed by structure + live keypress (the debug
  channel bypasses `performKeyEquivalent`).
- **Mouse — cmd+click opens URLs — ✅.** libghostty forwards the ⌘ modifier and
  emits `GHOSTTY_ACTION_OPEN_URL` when a terminal link is cmd+clicked; the action
  decodes into `GhosttyAction.openURL` and opens via `NSWorkspace`, matching
  upstream Ghostty (any parsable URL, no scheme restriction).
- Remaining for CasperUI: splits/tabs layout composition (actions are decoded
  and routed through `GhosttyActionDispatcher`, but not composed into a layout —
  **UI-3**; UI-1 renders only the single-terminal case); clipboard
  paste-confirmation UI (v1 auto-confirms); `flagsChanged` press/release
  semantics and scroll precision/momentum.

### CasperUI — ✅ UI-1..UI-5 built (live GUI check done)
The module exists. **UI-1** is done: a SwiftUI `App` scene
(`CasperApp`/`AppDelegate`/`CasperUI.runApp`) replaces the Ghostty demo as the
GUI entry point; a `@MainActor @Observable AppModel` owns the session and bridges
the core types to SwiftUI; a `NavigationSplitView` shows an empty state, an
"Add folder…" flow and one live terminal per workspace; and all startup wiring is
landed (per-surface env, the release control channel, session persistence,
`#if DEBUG` debug bridge). Release gating verified (no
debug symbols in `make release`). UI-1 is verified live on a real desktop session.

**UI-2** is done: the `Space` level (`Session → Space → Workspace`; `repoPath`
moved up to `Space.folderPath`; `Workspace` gained `kind: primary|linked` and
`baseBranch`). Opening a folder builds a Space — Git or not (non-Git folders are
degenerate Spaces: one primary, no worktree creation), promoted to Git when a
`.git` appears — detected live by the workspace filesystem watcher (and once per
Space at launch), and demoted back if the `.git` is removed. A per-Space "+"
creates a **linked** workspace as a new branch + `git worktree` at a visible
sibling of the repo folder, `<parent>/<repo>-<branch>` (outside the repo, so
naturally untracked — the old in-repo `.casper/worktrees/` layout and its
`.git/info/exclude` entry are gone; a `-2`/`-3`… suffix is used if the sibling
name is taken). The sidebar is grouped by Space in
collapsible sections; removal is non-destructive (drop a linked workspace or a
whole Space, leaving worktrees/branches on disk). Persistence is a clean break
(the `SessionStore` self-heal discards incompatible legacy `session.json`). The
`+/−` diff summary is deferred to UI-5.

**UI-3** is done: a workspace renders its `LayoutNode` tree recursively — splits
as native `HSplitView`/`VSplitView`; a tab group renders only its active surface
(Ghostty-style tab bar: rounded "pill" tabs sharing the width equally, centered
titles, the active tab a filled bordered pill and inactive tabs blended into a
fixed dark neutral chrome — no accent color; the whole pill is clickable; a
trailing circular `+` menu; each tab has a leading hover-revealed `×` that closes
that surface by `Surface.id`, preserving the active tab when a background tab is
closed; tying the shades to the live terminal background and `⌘N` switch
shortcuts are deferred), with
inactive surfaces kept alive in a persistent cache (PTYs running) and re-attached
on re-selection (rendering only the active surface avoids overlapping
`CAMetalLayer` terminals that ignore SwiftUI opacity). Pure `LayoutTree` operations
(`insertTab`/`split`/`closeSurface`) live in CasperCore; libghostty
`newTab`/`newSplit`/`closeTab` route through a `LayoutActionHandler` (installed on
`GhosttyRuntime.actionHandler`) to the focused workspace, focus tracked via the
surface first-responder callback added in CasperGhostty. Closing the last surface
closes the workspace non-destructively. Surface views live in a persistent cache
keyed by `Surface.id` so PTYs/web state survive restructuring.

**UI-4** is done: `.browser` leaves render a `WKWebView` surface (address bar with
bare-host normalization, back/forward/reload), created via the tab-bar "+" menu
(New terminal / New browser). The web view is cached by `Surface.id` (the cache
generalized to any `NSView`) and its URL persists via the address bar. Only
`.diff` leaves remain a placeholder (UI-5).

**UI-5** is done: `.diff` leaves render a read-only diff surface over
`diffWorkdirToHead()` — per-file sections (path + status, binary noted), hunk
headers, and monospaced line rows colored by kind (addition/deletion/context)
with old/new line-number gutters; computed on open and **live-refreshed** by a
native FSEvents watcher on the selected workspace's folder (debounced ~200 ms;
`.git` + Git-ignored top-level dirs excluded) that bumps an observable revision
driving both the diff surface and the title-bar `+/−` badge.

> **Superseded:** the `.diff` layout-leaf surface kind (and its "New diff"
> tab-bar menu item) was later **removed** — the diff view now lives **only** in
> the right inspector panel (`Workspace.inspector`, see below). The `.browser`
> layout-leaf path still exists; `.diff` does not. The diff rendering described
> above is unchanged, just hosted by the inspector instead of a layout leaf.

All five CasperUI sub-projects are built. **Live GUI check: done.** Terminals
render on a restored session and tab switching preserves content — verified via
the `casper debug` channel on a real desktop (this fixed a restore-path bug where
a non-observed `runtime` left terminals black; see the ledger).

Post-milestone tab-bar polish landed (all on `main`, not pushed; see the ledger's
"Tab-bar polish" section for commit hashes): a per-tab hover-revealed `×` close
button (closing any surface by `Surface.id`, preserving the active tab when a
background tab closes — with a regression test), Ghostty-style rounded "pill"
tabs sharing the width with centered titles and a circular `+` menu, full-tab
click (not just the title), and a fix so a clicked tab's terminal takes AppKit
keyboard focus (`focusActiveSurfaceView()` → deferred `makeFirstResponder`).

Still to verify live: the terminal-focus-on-tab-switch fix (click a
tab, then type — the keystroke must reach the terminal), the Ghostty tab
appearance vs the reference screenshot, full-tab click, and — open from before —
splits, browser navigation, and the diff surface. Deferred follow-ups: deriving
tab shades from the live terminal background color (Casper does not yet read
libghostty's `background-color`), and per-tab `⌘N` switch shortcuts.

## Surface layout — tmux-style panes (supersedes UI-3 tabs) — ✅

The tabbed surface model (UI-3) is replaced by a **tmux-style layout**: no tabs,
one surface per pane. Landed on `main` (not pushed) in three commits:

- `656ce2a` Replace tabbed surfaces with a tmux-style pane layout
- `ad9847c` Close a terminal surface when its process exits
- `6b0dbab` Fix blank pane on split collapse from shared NSView host

**Model.** `LayoutNode` is now `split | leaf(Surface)` (no `tabGroup`); each leaf
holds one surface. A hand-written `LayoutNode` `Codable` migrates persisted
`tabGroup` sessions (N surfaces → even horizontal split of N leaves).
`LayoutTree` keeps `split`/`closeSurface`/`mapSurface`/`surfaceIDs`;
`insertTab`/`activate` are removed. `GitDiff` gained `insertions`/`deletions`.

**Rendering.** Leaves render via `SurfaceHostView` (no tab bar; `TabBarView`
deleted). Right-click on a pane opens the pane menu: Split up/down/left/right
(each creates a terminal), Copy/Paste, Close pane. Splits render via a custom
`SplitContainerView` (replacing native `HSplitView`/`VSplitView`) that separates
panes with system `Divider()`s — so every separator in the app (sidebar/content
edge, inspector panel, inter-pane) shares one color; the native split divider was
darker (near-black) and stood out. Panes are laid out by fraction along the axis
with draggable `Divider()` handles (left-right / up-down resize cursor); fractions
live in local `@State` (resize is not persisted, matching v1). Leaves keep
explicit non-overlapping frames so the Metal-backed terminals never occlude.

**Chrome.** The native window toolbar (with the native sidebar toggle) shows the
branch-icon title + worktree path, the `+ins −del` diff summary
(`AppModel.diffSummary` via `computeDiff`), and side-by-side new-terminal /
new-browser buttons (both split right). "Add Space" stays sidebar-side. Sidebar
rows show a neutral branch icon, a full-width todo progress bar with the current
task, and a notification bubble; Spaces stay collapsible; the per-Space "+" adds a
linked workspace.

**Close-on-exit.** libghostty `close_surface_cb` (Ctrl-D / `exit`) is wired via
`GhosttySurfaceView.onClose` → `AppModel.applyCloseSurface`; closing the last pane
closes the workspace non-destructively. The callback defers to the next runloop
turn (like `wakeup_cb`) to avoid re-entering the runtime mid-tick.

**Bug fixed.** On a split→leaf collapse a stale SwiftUI host stole the survivor's
shared `NSView` into a container about to leave the window, blanking the pane.
`PersistentNSViewHost` now runs a next-runloop, window-guarded reconcile so only
the host whose container stays in the window keeps the view. See the
`persistent-nsview-host-sharing` project-memory note.

**Verified** via the `casper debug` channel + screenshots on a real desktop:
`tabGroup`→`leaf` session migration, continuous split panes with no tab bar,
terminal + browser panes side by side, sidebar progress/notification, the live
diff summary, and close-on-exit collapsing two panes to one (the survivor stays
rendered). `swift test` → 259 passing.

**Follow-ups.** (1) Browser panes: WebKit consumes the right-click, so the Casper
split menu does not yet surface over live web content (the native menu is
suppressed). (2) The toolbar diff summary uses working-tree-vs-HEAD; the Space
branch-vs-merge-base `+/−` summary was **dropped** (decision 2026-07-06), so this
is now the intended behaviour, not a stopgap.

## Right inspector panel — ✅ (live check done)

A collapsible right-side panel on the workspace detail view exposes a **browser**
and the **Git diff** as two tabs, per workspace. The `.diff` layout-leaf surface
kind was **removed** — the diff view now lives **only** in this inspector panel.
The `.browser` layout-leaf path still exists (a browser can still be a tmux
pane); `.diff` does not. The title-bar globe "New browser" button is removed.

**Model.** `Workspace` gained `inspector: InspectorState` (`collapsed`, `tab:
InspectorTab{browser,diff}`, and a dedicated `browser: Surface`). A hand-written
`Workspace.init(from:)` decodes `inspector` with `decodeIfPresent ?? .init()` so
pre-existing `session.json` files load with a default (collapsed, Diff tab,
`about:blank` browser); `encode` stays synthesized. State is per-workspace and
persisted.

**UI.** `WorkspaceDetailView` lays the detail out as an `HStack`: the tmux
`LayoutNodeView` (`maxWidth: .infinity`), a `Divider()` (system separator, matching
the sidebar/content edge), then `InspectorPanel` at a state-driven `width` (default 480,
clamped 240–1400) shown only when expanded. The `Divider()` doubles as a drag handle
(transparent 10 pt hit area, left-right resize cursor) that resizes the panel; the
width lives in view `@State`, so it is **preserved across collapse/expand** and,
because the left region stays `maxWidth: .infinity`, **unaffected by adding
terminals**. It is a side region, not an `HSplitView` pane (which would reset the
width on re-add). Width is not yet persisted across workspace switches or restarts. `InspectorPanel` is a native segmented Browser|Diff
selector pinned to the top over **full-bleed** content (no insets — a native
`TabView`'s mandatory content inset was rejected), reusing `BrowserSurfaceView` (on
`inspector.browser`) and `DiffSurfaceView` unchanged. The panel is collapsed only
via the title-bar toggle (no in-panel collapse button). The panel browser's
`WKWebView` survives collapse/expand and workspace switches via the existing
surface-view cache (stable `Surface.id`); its address-bar URL write-back reaches
`inspector.browser` through an extended `setBrowserURL` (fall-through on a
`locateSurface` miss). Diff is on-demand (open + refresh).

**Chrome.** The title bar drops the globe "New browser" button and gains a panel
toggle (`sidebar.right`, tinted when expanded); the `+ins −del` diff summary is now
a button that expands the panel on the Diff tab. "New terminal" is unchanged.

**Tests.** `swift test` → 266 passing, incl. `InspectorState` defaults, `Workspace`
round-trip with a non-default inspector, legacy-decode without the `inspector` key,
the three `AppModel` inspector mutators, and the inspector-browser URL write-back.

**Verified.** Live GUI pass (`debug-casper`): panel toggle, tab switch, browser
survival across collapse/expand and workspace switch, and a terminal pane not
blanked when toggling the panel (see `persistent-nsview-host-sharing`).

## Developer tooling (`#if DEBUG`)

- **Debug & observability channel — ✅.** `DebugProtocol`/`DebugSocket`/
  `DebugServer`/`DebugCLICommand`; verbs `dump-state`/`read-text`/`send-text`/
  `screenshot`. As-built deviations are recorded in the observability spec §6.
- **Debug surface addressing — ✅.** Stable surface `id`, `focus` verb,
  `--target` option.

Gated entirely at compile time; physically absent from `make release`.

## Space (project) — ◐
The **Space** model shipped with CasperUI UI-2 (`Session → Space → Workspace`;
`repoPath` up to `Space.folderPath`; `Workspace.kind`/`baseBranch`; Space-grouped
sidebar; `Repository.remoteURL` + `origin` name derivation). What remains for this
feature is **Space rename** only.

The per-workspace **`+/−` diff summary** (branch-vs-merge-base divergence badge)
is **dropped** (decision 2026-07-06) — the title-bar working-tree-vs-HEAD summary
covers the need. The old task-by-task plan (`plans/space-project.md`) is
superseded: its model/remote/naming tasks landed with UI-2, and its divergence
tasks are moot.

## Agent-state detection — ◐
Infers `Workspace.agentState` (`working | blocked | idle | done | unknown |
error`) by scraping the terminal, no hooks. Design: `themes/agent-state-detection.md`.

**Built & live-verified:** the pure engine (`CasperCore/AgentDetection.swift` —
data-driven matchers for both the viewport (`blocked`) and the OSC title
(`working`/`idle`), most-urgent aggregation, debounce/`done`-latch resolver, 29
tests); non-DEBUG `readViewportText()` and `readOSCTitle()` accessors (the latter
fed by `GHOSTTY_ACTION_SET_TITLE` captured per-surface); the `AppModel` timer
(~250 ms) that scrapes each workspace's terminals — viewport **and** title —
resolves, and writes `agentState` unless the workspace is under explicit
authority; the `casper status set` authority latch (transient) that stops
detection for that workspace; and the sidebar status icon (`WorkspaceRow`,
monochrome outline SF Symbols in the chevron column, animated `working`). Live
GUI check confirmed idle→working→idle, driven by the real OSC-title spinner
(current Claude Code's `working` marker), plus `blocked` from the viewport.

`done` is produced by the resolver's own `working → idle` derivation. `blocked`/
`done` (and `error`, for the explicit-only path) are wired to `casper notify` +
`pendingNotification` (`AppModel.controlRaiseNotification`), with an
interruption level (`.passive` for `done`, `.active` for `blocked`/`error`) and
a per-workspace 3s de-dup cooldown against near-simultaneous explicit/detected
notifies for the same event. See
`plans/notification-idle-best-practices.md`.

**Not implemented (by decision):** a process-exit (`childExited`) `done`/`error`
producer + authority release. It only fits an *agent-as-command* surface, which
Casper can't create — the embedded libghostty (a sandbox/host-managed fork) does
not spawn a surface's `command` (a plain shell launches; this also makes `casper
terminal new --command X` inert). Agents therefore run inside a shell; `error`
has no detected producer and authority release is deferred to the timeout
mechanism (option B). The initial implementation was removed. See the theme's
"Process lifecycle" section.

**Deferred:** `.render`-driven trigger (timer poll for now); option-B timeout
authority release; per-surface status (option B); agents beyond Claude Code
(per-agent rule sets).

## Remaining work — dependency-ordered

1. **CasperGit `git_diff` — ✅ built** (`diffWorkdirToHead()`); the diff viewer is
   unblocked.
2. **CasperUI (Plan 5) — ✅ built.** All of UI-1..UI-5 (app shell + startup wiring;
   Space model + Space-grouped sidebar + linked Git worktrees; recursive
   splits/tabs layout; WKWebView browser surface; read-only diff viewer). The live
   GUI verification pass on a real desktop is complete.
3. **Space rename** — the Space data-model change and sidebar grouping landed in
   UI-2; what remains is renaming a Space from the sidebar. (The `+/−` diff
   summary that used to live here is **dropped** — decision 2026-07-06.)
