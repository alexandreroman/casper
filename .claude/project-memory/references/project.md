---
name: project
description: "What Casper is, its architecture, and the 5-plan roadmap with current status"
type: project
---

# project

**Casper** — a native macOS app (SwiftUI + targeted AppKit) that embeds
**libghostty** (via GhosttyKit) to give each **Git worktree** a terminal
workspace, specialized for code agents. Core features: per-workspace agent-state
+ todo-progress tracking (via Claude Code hooks → Unix socket → `AgentStateStore`),
free-form splits/tabs layout, integrated WKWebView browser, native diff viewer,
per-workspace 10-port reservation (`CASPER_PORT`), single GUI+CLI
binary. In-process PTYs. Distributable, **no notarization**, arm64-only.

Source of truth: `docs/superpowers/specs/2026-07-01-casper-design.md` and the
implementation plans in `docs/superpowers/plans/`.

**Roadmap (5 plans):** 1. CasperCore (pure Swift core) · 2. CasperGit (libgit2
wrapper + WorktreeManager) · 3. CLI + Agents (single binary, `casper hooks`,
socket, Claude Code settings) · 4. CasperGhostty (embedding) · 5. CasperUI + app.

**Status (2026-07-02):** Plans 1, 2, 3 & 4 complete, committed on `main` (repo
local only, **not pushed** to GitHub yet). **131 XCTest tests green**
(`make test`). v1 agent target: Claude Code only. Plan 4's GUI terminal is
**manually verified** (design §13): `casper` opens a window with a live
GPU-rendered shell, `ls` runs, the cwd is the launch directory, and the window
title reflects the cwd — the latter confirms the C action-callback path
(`action_cb` → `ghostty_app_userdata` → `handleAction` → `onAction`) works
end-to-end (the one path with no unit coverage). Rendering is display-link
driven, so `GHOSTTY_ACTION_RENDER` needs no `draw()` wiring.
**Fixed (2026-07-02):** the terminal grid used to render ~2× too large and
overflow the window (right-edge truncation). Root cause: libghostty's own
`CAMetalLayer` kept `contentsScale = 1` while the window was at
`backingScaleFactor = 2`, so Core Animation upscaled the native render ×2. Fix:
`GhosttySurfaceView` now syncs `layer.contentsScale` to the window's backing
scale — see [[ghostty-layer-contents-scale]]. A DEBUG-only geometry readback
(`casper debug dump-state` now reports width_px/cell_px/content-scale) made the
diagnosis measurable.

- **Plan 1 — CasperCore:** implemented, reviewed. Pure Swift core.
- **Plan 2 — CasperGit + WorktreeManager:** implemented, reviewed (final
  whole-branch review clean, ready to merge). Adds a `Clibgit2` systemLibrary
  (libgit2 via Homebrew + pkg-config, dynamic link — static vendoring deferred to
  the packaging plan), the thin `CasperGit` wrapper (`Repository`: open/discover/
  init, branch queries, worktree add/list/lookup/validate/prune, status/isClean;
  `WorktreeInfo`/`GitError`), and `WorktreeManager` in CasperCore (create/list/
  remove/isClean with `WorktreeError` mapping). **56 XCTest tests green**
  (`make all`). Build now needs `brew install libgit2 pkgconf`.
  - Known v1 follow-ups (documented, non-blocking): `remove` prunes the worktree
    but not its branch, so recreating a same-named workspace surfaces an opaque
    `.gitFailure` (map to a clear reason or delete the branch on remove later);
    libgit2 is unpinned in brew/CI; `WorktreeManager` uses `Repository.open`
    (exact root) not `discover`.

- **Plan 3 — CLI + Agents:** implemented, reviewed (final whole-branch review:
  ready to merge). Adds `CasperAgents` (`ClaudeCodeAdapter` → `.claude/settings.local.json`
  + surface env; `HookMessage`; `HookSocketServer`/`Client` over a Unix-domain
  socket via Network.framework) and `CasperCLI` (`casper` executable, the
  `casper hooks setup` / `casper hooks feed` command family, GUI/CLI argv fork).
  `AgentStateStore`
  + `HeartbeatMonitor` + `unknown`/`error` transitions added to CasperCore. Only
  new dep: swift-argument-parser. See [[hooks-install-once]],
  [[swift6-network-concurrency]].
    `casper` is exposed only inside Casper-opened terminals via PATH injection in
    `surfaceEnvironment` (no global shim) — see [[casper-cli-availability]].
  - Deferred to Plan 5 (documented): the real GUI; wiring the app bundle's exec
    dir into `surfaceEnvironment(casperDirectory:basePath:)`; the heartbeat
    *timer*; socket robustness (`stop()` doesn't cancel in-flight connections; no
    read timeout/buffer cap; `start()` bind-wait unbounded; callback "set before
    start()" contract prose-only) — **must be closed before Plan 5 wires
    `onMessage` → `AgentStateStore`**.

- **Plan 4 — CasperGhostty:** implemented, reviewed (all 6 impl tasks approved).
  Embeds libghostty via the pinned `GhosttyKit` xcframework — the only module
  touching the unstable embedding API. Adds `GhosttyRuntime` (app + C runtime
  callbacks + wakeup→tick pump), `GhosttyAction` (pure action decoder),
  `GhosttySurface` (+ config marshaling), the AppKit `GhosttySurfaceView` host +
  SwiftUI `GhosttySurfaceRepresentable`, and `GhosttyDemo` (one-terminal window
  wired to `casper` GUI mode). See [[ghosttykit-pin]] for the exact version pin.
  - **Scope:** one live terminal end-to-end. **Deferred to Plan 5** (documented):
    splits/tabs *layout composition* (their actions are decoded but not acted on);
    clipboard copy/paste fidelity (callbacks are stubs); the `flagsChanged`
    press/release semantics and scroll precision/momentum bits.
  - Manual GUI checklist (design §13) still to be run by a human.

**Next milestone:** Plan 5 — CasperUI + the real app (SwiftUI sidebar, chrome,
diff, browser; splits/tabs layout; wire `onMessage` → `AgentStateStore`). Before
that wiring, close the Plan 3 socket-robustness Minors (see [[hooks-install-once]]).

See [[dependency-policy]], [[test-toolchain]], [[git-workflow]],
[[libgit2-swift-interop]], [[ghosttykit-pin]].
