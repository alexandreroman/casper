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

**Status (2026-07-02):** Plans 1, 2 & 3 complete, committed on `main` (repo local
only, **not pushed** to GitHub yet). **92 XCTest tests green** (`make test`). v1
agent target: Claude Code only.

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

**Next milestone:** Plan 4 — CasperGhostty (embed GhosttyKit/libghostty; surface
lifecycle, splits/tabs; the only module touching the unstable embedding API).

See [[dependency-policy]], [[test-toolchain]], [[git-workflow]],
[[libgit2-swift-interop]].
