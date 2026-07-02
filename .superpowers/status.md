# Casper — Implementation Status

The single, authoritative record of implementation progress. The design source of
truth is [`architecture.md`](architecture.md) plus the per-theme docs in
`themes/`; the documentation map is [`INDEX.md`](INDEX.md); active plans are in `plans/`.

Status legend: ✅ built · ◐ partial · ❌ not started.

## Roadmap at a glance

The build proceeds in five module plans. Plans 1–4 are implemented; CasperUI
(Plan 5, the real SwiftUI app) is the current milestone and is not yet built.
The v1 agent target is Claude Code only.

| Plan | Module | Status |
| --- | --- | --- |
| 1 | CasperCore | ✅ |
| 2 | CasperGit (+ Clibgit2) | ◐ worktrees/status built; `git_diff` missing |
| 3 | CasperCLI + CasperAgents | ✅ |
| 4 | CasperGhostty | ✅ one terminal end-to-end |
| 5 | CasperUI + app | ❌ not started (no plan written) |

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
- Remaining for CasperUI: wire `onMessage` → `AgentStateStore`; pass the app
  bundle's executable directory into
  `surfaceEnvironment(casperDirectory:basePath:)`; run the heartbeat timer.

### CasperGhostty — ✅ (one terminal end-to-end)
`GhosttyRuntime`, `GhosttyAction`, `GhosttySurface`, `GhosttySurfaceView`,
`GhosttySurfaceRepresentable`, `GhosttyDemo`. Rendering is display-link driven,
so `GHOSTTY_ACTION_RENDER` needs no explicit `draw()` wiring.
- Remaining for CasperUI: splits/tabs layout composition (actions are decoded
  but not acted on); clipboard copy/paste fidelity (callbacks are stubs);
  `flagsChanged` press/release semantics and scroll precision/momentum.

### CasperUI — ❌ not started
No module exists. Sidebar, chrome, splits/tabs layout composition, `WKWebView`
browser, and the diff viewer are all unbuilt. **No Plan 5 plan is written yet.**

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
2. **CasperUI (Plan 5)** — sidebar, chrome, splits/tabs layout composition,
   `WKWebView` browser, diff viewer, plus the wiring deferred from earlier plans
   (listed per module above). **Write the CasperUI / Plan 5 plan first — it does
   not exist yet.**
3. **Space (project) + diff summary** — data-model change (`repoPath` up to
   Space; `Workspace.kind`/`baseBranch`/derived `diffStat`), sidebar grouping,
   and the `+/−` row summary. Depends on 1 and 2.
