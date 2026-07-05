# Casper — Architecture & Foundation

Cross-cutting design that applies across every theme. Module-specific design
lives in `themes/`; implementation progress lives in `status.md`. The original
per-milestone specs and completed plans are recoverable from Git history (they
were tracked under the now-removed `docs/superpowers/` tree before being
distilled here).

## Vision

A native macOS app that embeds **libghostty** to give each **Git worktree** a
dedicated terminal workspace, specialized for running code agents (Claude Code
in v1). It surfaces each agent's live state and task progress in a sidebar, and
bundles a native browser and diff viewer. Distributable (self-signed / Homebrew
/ source), **no Apple notarization**.

## Hard constraints

1. **Native & performant** — macOS-native UI; GPU-accelerated terminal rendering
   via libghostty.
2. **Prefer built-in macOS frameworks** over third-party code.
3. **Minimum dependencies** — only three external deps (GhosttyKit,
   swift-argument-parser, and libgit2 behind the in-house `CasperGit`);
   everything else uses system frameworks. See [[dependency-policy]] for the full
   rule, rationale, and the arm64 / `-Osize` build stance.
4. **No notarization.**

## Locked decisions

- **Embedding:** GhosttyKit / libghostty-spm, **version pinned**, isolated behind
  the single `CasperGhostty` module (the embedding API is unstable — a bump
  touches only that module). See [[ghosttykit-pin]].
- **Process model: in-process.** Surfaces and their PTYs live in the Casper
  process; if Casper quits, running agents die (accepted). Relaunch restores the
  layout with fresh PTYs.
- **UI stack:** SwiftUI for chrome/sidebar/diff/browser; targeted AppKit
  (`NSViewRepresentable`, responder chain) to host Ghostty surfaces.
- **Single binary:** one executable is both the GUI app and the CLI (empty argv →
  GUI; a recognized subcommand → CLI).
- **v1 agent:** Claude Code only.

## Module boundaries

| Module | Responsibility | Theme |
| --- | --- | --- |
| **CasperGit** | Thin wrapper over the libgit2 C API: worktrees, diff, status, branch/base | `themes/git-worktrees.md` |
| **CasperCore** | Models, `SessionStore`, `AgentStateStore`, `WorktreeManager`, `PortAllocator`. Pure Swift, no UI | `themes/core.md` |
| **CasperGhostty** | `GhosttyRuntime`: wraps GhosttyKit, owns surface lifecycle + splits/tabs. The only module touching the unstable API | `themes/terminal.md` |
| **CasperAgents** | Claude Code adapter + hooks `settings.json` generation + the hook socket | `themes/cli-agents.md` |
| **CasperCLI** | `casper` subcommand dispatch (swift-argument-parser) | `themes/cli-agents.md` |
| **CasperUI** | SwiftUI sidebar, chrome, diff, browser + AppKit bridges | `themes/app-ui.md` |
| **Casper** (app) | Wiring, window, lifecycle, GUI/CLI dispatch | all |

Rationale: instability (libghostty), Git specifics (libgit2), and agent
specifics (Claude Code) are each confined to one module, so churn stays local.

## Data model (canonical)

```
Session
 └─ [Space]                          // a Git repository (see themes/space-project.md)
     └─ [Workspace]
         ├─ id, name, kind: primary | linked
         ├─ worktreePath, branch, baseBranch
         ├─ agentState: idle | running | waiting | done | error | unknown
         ├─ todos: [Todo{content, status: pending|in_progress|completed}]
         ├─ pendingNotification: Bool
         ├─ diffStat: {insertions, deletions}   // derived, not persisted
         ├─ portBase: Int                        // 10-port block; env CASPER_PORT
         └─ layout: LayoutNode

LayoutNode = Split(orientation, children, ratios) | TabGroup(surfaces, activeIndex)
Surface    = Terminal(cwd, command?) | Browser(url) | Diff(target)
```

The **Space** layer and `kind`/`baseBranch`/`diffStat` are introduced by
`themes/space-project.md` (not yet implemented). Persistence: `SessionStore`
serializes the whole tree to `~/Library/Application Support/Casper/session.json`
(`Codable`, debounced); terminals restart cold, browser/diff surfaces reload
their target, `portBase` is restored as-is.

## Risks & mitigations

| Risk | Mitigation |
| --- | --- |
| libghostty API instability | All access behind `GhosttyRuntime`; pinned version |
| Worktree op fails (branch checked out, dirty) | Clear UI error, never crash |
| PTY dies | Surface marked closed, restartable |
| App crash | Agents lost (accepted); relaunch restores layout cold |
| Agent without hooks | State `unknown`, non-blocking |
| Binary size creep | Three justified externals only; arm64-only; `-Osize` + LTO |

## Testing strategy

- **Unit (XCTest):** `WorktreeManager`, `AgentStateStore`, hook parsing,
  `SessionStore` round-trip, `PortAllocator`. Needs the full Xcode toolchain —
  see [[test-toolchain]].
- **Integration:** end-to-end adapter driven by a fake agent over the socket.
- **Manual:** terminal rendering, keyboard/focus, notifications — via the
  `debug-casper` harness (`themes/debug.md`).

## v1 scope

**In:** worktree=workspace, free-form splits/tabs, terminal + browser + diff
surfaces, per-workspace 10-port reservation, Claude Code state + todo progress,
enriched sidebar, session persistence, single GUI+CLI binary, arm64-only.

**Out (later):** persistent daemon (agents surviving restart), multi-agent
orchestration, more agent adapters (Codex, Gemini), editable diffs, notarized
distribution.
