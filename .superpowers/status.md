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
browser surface), and **UI-5** (read-only diff viewer). A live GUI verification
pass on a real desktop remains. The v1 agent target is Claude Code only.

| Plan | Module | Status |
| --- | --- | --- |
| 1 | CasperCore | ✅ |
| 2 | CasperGit (+ Clibgit2) | ✅ worktrees/status/`remoteURL`/`git_diff` built |
| 3 | CasperCLI + CasperAgents | ✅ |
| 4 | CasperGhostty | ✅ one terminal + splits/tabs composed by UI-3 |
| 5 | CasperUI + app | ✅ UI-1..UI-5 built (sidebar + worktrees + splits/tabs + browser + diff); live GUI check pending |

Two developer-tooling features are built on top (both `#if DEBUG`): the
debug/observability channel and debug surface addressing. The Space (project) +
workspace diff-summary feature is design + plan only.

> **Latest work — the tabbed surface model (UI-3) is replaced by a tmux-style
> pane layout** (no tabs, one surface per pane), with close-on-process-exit and a
> shared-NSView collapse fix. See
> [Surface layout — tmux-style panes](#surface-layout--tmux-style-panes-supersedes-ui-3-tabs--) below. UI-3 sections in this file and in `themes/app-ui.md`
> describe the superseded tab model.

## Modules

### CasperCore — ✅
Models, `AgentStateStore`, `HeartbeatMonitor`, `WorktreeManager`
(create/list/remove/isClean with `WorktreeError` mapping), `PortAllocator`,
`SessionStore`, hook parsing, and the agent-state reducer.

### CasperGit + Clibgit2 — ✅ (core)
`Repository` (open/discover/init, branch queries, worktree
add/list/lookup/validate/prune, status/isClean, `remoteURL`, `diffWorkdirToHead`),
`Worktree`, `GitError`.
- **`git_diff` is built** — `diffWorkdirToHead()` returns a structured
  `GitDiff` (files → hunks → lines, statuses, binary flag; working tree + index
  vs HEAD, unborn HEAD as additions), unblocking the diff viewer (design §11).
  Branch-divergence diffs for the Space `+/−` summary (Space §6) remain.
- Standing limitations: `remove` prunes the worktree but not its branch, so
  recreating a same-named workspace surfaces an opaque `.gitFailure` (fix by
  mapping it to a clear reason or deleting the branch on remove); libgit2 is
  unpinned in brew/CI; `WorktreeManager` opens the exact repo root
  (`Repository.open`) rather than `discover`.

### CasperAgents + CasperCLI — ✅
`ClaudeCodeAdapter`, `HookMessage`, `HookSocketServer`/`Client`; the `casper`
executable with `casper hooks setup` / `casper hooks feed` and the GUI/CLI fork.
- Wired by CasperUI UI-1: `onMessage` → agent-state reducer on `AppModel`'s
  observable workspaces; the bundle executable directory is passed into
  `surfaceEnvironment(casperDirectory:basePath:)`; the heartbeat timer runs.

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
- Remaining for CasperUI: splits/tabs layout composition (actions are decoded
  and routed through `GhosttyActionDispatcher`, but not composed into a layout —
  **UI-3**; UI-1 renders only the single-terminal case); clipboard
  paste-confirmation UI (v1 auto-confirms); `flagsChanged` press/release
  semantics and scroll precision/momentum.

### CasperUI — ✅ UI-1..UI-5 built (live GUI check partial)
The module exists. **UI-1** is done: a SwiftUI `App` scene
(`CasperApp`/`AppDelegate`/`CasperUI.runApp`) replaces the Ghostty demo as the
GUI entry point; a `@MainActor @Observable AppModel` owns the session and bridges
the core types to SwiftUI; a `NavigationSplitView` shows an empty state, an
"Add folder…" flow and one live terminal per workspace; and all startup wiring is
landed (hooks install, hook socket → agent state, per-surface env, heartbeat
timer, session persistence, `#if DEBUG` debug bridge). Release gating verified (no
debug symbols in `make release`). UI-1 is verified live on a real desktop session.

**UI-2** is done: the `Space` level (`Session → Space → Workspace`; `repoPath`
moved up to `Space.folderPath`; `Workspace` gained `kind: primary|linked` and
`baseBranch`). Opening a folder builds a Space — Git or not (non-Git folders are
degenerate Spaces: one primary, no worktree creation), promoted to Git on the
heartbeat when a `.git` appears. A per-Space "+" creates a **linked** workspace as
a new branch + `git worktree` under `<folder>/.casper/worktrees/<branch>`
(`.casper/` added to `.git/info/exclude`). The sidebar is grouped by Space in
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
with old/new line-number gutters; computed on open + a refresh button; created via
the tab-bar "+" menu (New diff).

All five CasperUI sub-projects are built. **Live GUI check (partial):** terminals
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
(each creates a terminal), Copy/Paste, Close pane. Panes tile with the native
split-view divider only (no per-pane chrome).

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
branch-vs-merge-base `+/−` summary (Space §6) is still open. (3) A broad live GUI
pass on the new chrome (context-menu split actions, toolbar buttons) beyond the
debug channel.

## Developer tooling (`#if DEBUG`)

- **Debug & observability channel — ✅.** `DebugProtocol`/`DebugSocket`/
  `DebugServer`/`DebugCLICommand`; verbs `dump-state`/`read-text`/`send-text`/
  `screenshot`. As-built deviations are recorded in the observability spec §6.
- **Debug surface addressing — ✅.** Stable surface `id`, `focus` verb,
  `--target` option.

Gated entirely at compile time; physically absent from `make release`.

## Space (project) & workspace diff summary — ◐
The **Space** model shipped with CasperUI UI-2 (`Session → Space → Workspace`;
`repoPath` up to `Space.folderPath`; `Workspace.kind`/`baseBranch`; Space-grouped
sidebar; `Repository.remoteURL` + `origin` name derivation). What remains for this
feature is the **`+/−` diff summary** per workspace row (derived `diffStat`,
depends on CasperGit `git_diff`) and **Space rename**.

## Remaining work — dependency-ordered

1. **CasperGit `git_diff` — ✅ built** (`diffWorkdirToHead()`); the diff viewer is
   unblocked. Branch-divergence diffs for the Space `+/−` summary (Space §6)
   remain.
2. **CasperUI (Plan 5) — ✅ built.** All of UI-1..UI-5 (app shell + startup wiring;
   Space model + Space-grouped sidebar + linked Git worktrees; recursive
   splits/tabs layout; WKWebView browser surface; read-only diff viewer). A live
   GUI verification pass on a real desktop remains.
3. **Space diff summary** — the Space data-model change and sidebar grouping
   landed in UI-2; what remains is the derived `diffStat` and the `+/−` row
   summary (depends on 1), plus Space rename.
