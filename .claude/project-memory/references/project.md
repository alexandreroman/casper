---
name: project
description: "What Casper is, its architecture, and the module build state"
type: project
---

# project

**Casper** — a native macOS app (SwiftUI + targeted AppKit) that embeds
**libghostty** (via GhosttyKit) to give each **Git worktree** a terminal
workspace, specialized for code agents. Core features: per-workspace agent-state
+ todo-progress tracking (Claude Code hooks → Unix socket → `AgentStateStore`),
free-form splits/tabs layout, integrated WKWebView browser, native diff viewer,
per-workspace 10-port reservation (`CASPER_PORT`), a single GUI+CLI binary, and
in-process PTYs. Distributable, **no notarization**, arm64-only.

Source of truth: the design spec and implementation plans under
`docs/superpowers/specs/` and `docs/superpowers/plans/`.

**Build roadmap — five module plans:** 1. CasperCore (pure Swift core) ·
2. CasperGit (libgit2 wrapper + `WorktreeManager`) · 3. CasperCLI + CasperAgents
(single binary, `casper hooks`, socket, Claude Code settings) · 4. CasperGhostty
(embedding) · 5. CasperUI + the app. Modules 1–4 are implemented; **CasperUI —
the real SwiftUI app** (sidebar, chrome, diff, browser, splits/tabs layout, and
the `onMessage` → `AgentStateStore` wiring) — is the current milestone and is
not yet built. The v1 agent target is Claude Code only.

- **CasperCore** — the pure-Swift core: models, `AgentStateStore`,
  `HeartbeatMonitor`, `WorktreeManager` (create/list/remove/isClean with
  `WorktreeError` mapping), the port allocator, hook parsing, and the
  agent-state reducer.
- **CasperGit + Clibgit2** — `Clibgit2` is a `.systemLibrary` binding libgit2
  via Homebrew + pkg-config (dynamic link; static vendoring is deferred to the
  packaging plan). `CasperGit` is the thin wrapper: `Repository`
  (open/discover/init, branch queries, worktree add/list/lookup/validate/prune,
  status/isClean), `WorktreeInfo`, `GitError`. Building needs
  `brew install libgit2 pkgconf`.
  - Standing limitations: `remove` prunes the worktree but not its branch, so
    recreating a same-named workspace surfaces an opaque `.gitFailure` (fix by
    mapping it to a clear reason or deleting the branch on remove); libgit2 is
    unpinned in brew/CI; `WorktreeManager` opens the exact repo root
    (`Repository.open`) rather than `discover`.
- **CasperAgents** — `ClaudeCodeAdapter` (merges hooks into
  `~/.claude/settings.json`; builds per-surface env), `HookMessage`, and
  `HookSocketServer`/`Client` over a Unix-domain socket (Network.framework). Its
  only added dependency is swift-argument-parser. See [[hooks-install-once]],
  [[swift6-network-concurrency]], [[cli-availability]].
- **CasperCLI** — the `casper` executable, the `casper hooks setup` /
  `casper hooks feed` command family, and the GUI/CLI argv fork.
  - Remaining for CasperUI: wire `onMessage` → `AgentStateStore`; pass the app
    bundle's executable directory into
    `surfaceEnvironment(casperDirectory:basePath:)`; run the heartbeat timer.
- **CasperGhostty** — embeds libghostty through the pinned `GhosttyKit`
  xcframework (the only module touching the unstable embedding API):
  `GhosttyRuntime` (app + C runtime callbacks + wakeup→tick pump),
  `GhosttyAction` (pure action decoder), `GhosttySurface` (+ config marshaling),
  the AppKit `GhosttySurfaceView` host, the SwiftUI
  `GhosttySurfaceRepresentable`, and `GhosttyDemo` (one-terminal window wired to
  `casper` GUI mode). Scope is one live terminal end-to-end. Rendering is
  display-link driven, so `GHOSTTY_ACTION_RENDER` needs no explicit `draw()`
  wiring. See [[ghosttykit-pin]].
  - Remaining for CasperUI: splits/tabs *layout composition* (actions are
    decoded but not acted on); clipboard copy/paste fidelity (callbacks are
    stubs); `flagsChanged` press/release semantics and scroll
    precision/momentum. Correct glyph size depends on syncing the Metal layer
    scale — see [[ghostty-layer-contents-scale]].

Beyond the five build plans, design specs and plans under `docs/superpowers/`
also cover debug observability, debug surface addressing/focus, and Space
(project) + workspace diff-summary.

See [[dependency-policy]], [[test-toolchain]], [[git-workflow]],
[[libgit2-swift-interop]], [[ghosttykit-pin]], [[debug-channel-gating]].
