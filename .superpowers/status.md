# Casper — Implementation Status

The single, authoritative record of implementation progress. The design source of
truth is [`architecture.md`](architecture.md) plus the per-theme docs in
`themes/`; the documentation map is [`INDEX.md`](INDEX.md); active plans are in `plans/`.

Status legend: ✅ built · ◐ partial · ❌ not started.

## Roadmap at a glance

The build proceeds in five module plans. Plans 1–4 are implemented; CasperUI
(Plan 5, the real SwiftUI app) is the current milestone and is under way — its
first sub-project **UI-1** (app shell + minimal sidebar + one terminal + startup
wiring) is built; UI-2…UI-5 remain. The v1 agent target is Claude Code only.

| Plan | Module | Status |
| --- | --- | --- |
| 1 | CasperCore | ✅ |
| 2 | CasperGit (+ Clibgit2) | ◐ worktrees/status built; `git_diff` missing |
| 3 | CasperCLI + CasperAgents | ✅ |
| 4 | CasperGhostty | ✅ one terminal end-to-end |
| 5 | CasperUI + app | ◐ UI-1 built (shell + sidebar + one terminal + wiring); UI-2…UI-5 remain |

Two developer-tooling features are built on top (both `#if DEBUG`): the
debug/observability channel and debug surface addressing. The Space (project) +
workspace diff-summary feature is design + plan only.

## Modules

### CasperCore — ✅
Models, `AgentStateStore`, `HeartbeatMonitor`, `WorktreeManager`
(create/list/remove/isClean with `WorktreeError` mapping), `PortAllocator`,
`SessionStore`, hook parsing, and the agent-state reducer.

### CasperGit + Clibgit2 — ◐
`Repository` (open/discover/init, branch queries, worktree
add/list/lookup/validate/prune, status/isClean), `Worktree`, `GitError`.
- **`git_diff` is not implemented** — prerequisite for the diff viewer
  (design §11) and the workspace diff summary (Space §6).
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

### CasperUI — ◐ UI-1 built
The module exists. **UI-1** is done: a SwiftUI `App` scene
(`CasperApp`/`AppDelegate`/`CasperUI.runApp`) replaces the Ghostty demo as the
GUI entry point; a `@MainActor @Observable AppModel` owns the session and bridges
the core types to SwiftUI; a `NavigationSplitView` shows an empty state, an
"Add folder…" flow (adopt any folder as a workspace — Git or not, multiple
allowed) and one live terminal per workspace; and all startup wiring is landed
(hooks install, hook socket → agent state, per-surface env, heartbeat timer,
session persistence, `#if DEBUG` debug bridge). Release gating verified (no debug
symbols in `make release`).

UI-1 is verified live on a real desktop session (the headless sandbox cannot
materialize the SwiftUI detail `NSHostingView`, so live checks require a real
window server).

Remaining CasperUI sub-projects: **UI-2** multi-workspace via Git worktrees +
Space grouping; **UI-3** recursive splits/tabs layout; **UI-4** `WKWebView`
browser; **UI-5** diff viewer (needs `git_diff`).

## Developer tooling (`#if DEBUG`)

- **Debug & observability channel — ✅.** `DebugProtocol`/`DebugSocket`/
  `DebugServer`/`DebugCLICommand`; verbs `dump-state`/`read-text`/`send-text`/
  `screenshot`. As-built deviations are recorded in the observability spec §6.
- **Debug surface addressing — ✅.** Stable surface `id`, `focus` verb,
  `--target` option.

Gated entirely at compile time; physically absent from `make release`.

## Space (project) & workspace diff summary — ❌
Design + plan only; no `Space` type exists. Promotes the sidebar's implicit repo
grouping into a first-class **Space** (`Session → Space → Workspace`; `repoPath`
moves up to Space; `Workspace` gains `kind`/`baseBranch`/derived `diffStat`) and
adds a `+/−` diff summary per workspace row. Depends on CasperGit `git_diff` and
CasperUI.

## Remaining work — dependency-ordered

1. **CasperGit `git_diff`** — unblocks the diff viewer (design §11) and the
   workspace diff summary (Space §6).
2. **CasperUI (Plan 5)** — decomposed into UI-1…UI-5. **UI-1 is built** (app
   shell + minimal sidebar + one terminal + all deferred startup wiring). Next:
   **UI-2** (multi-workspace via Git worktrees + Space grouping), **UI-3**
   (recursive splits/tabs layout), **UI-4** (`WKWebView` browser), **UI-5** (diff
   viewer — depends on `git_diff`). Each sub-project gets its own spec → plan →
   build cycle.
3. **Space (project) + diff summary** — data-model change (`repoPath` up to
   Space; `Workspace.kind`/`baseBranch`/derived `diffStat`), sidebar grouping,
   and the `+/−` row summary. Depends on 1 and 2.
