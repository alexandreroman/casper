# Casper — Design Specification

**Date:** 2026-07-01
**Status:** Approved design, pending implementation plan
**Author:** Alexandre Roman (with Claude)

## 1. Vision

Casper is a native macOS application that embeds **libghostty** to give each
**Git worktree** a dedicated terminal workspace, specialized for running code
agents (Claude Code in v1). It surfaces each agent's live state and task
progress in a sidebar, and bundles two developer conveniences: an integrated
native browser and a diff viewer.

Casper is intended as a distributable product (self-signed / Homebrew / source —
**no Apple notarization**), not merely a personal tool.

## 2. Hard Constraints

These constraints override convenience and shape every technical decision:

1. **Native & performant.** macOS-native UI and behavior; GPU-accelerated
   terminal rendering via libghostty.
2. **Prefer built-in macOS frameworks/APIs** over third-party code.
3. **Smallest possible binary, minimum external dependencies.**
   Prefer built-in macOS frameworks. Exactly **three** external dependencies are
   justified and allowed; everything else uses system frameworks:
   - **GhosttyKit** — the libghostty XCFramework (terminal engine).
   - **swift-argument-parser** (Apple) — CLI parsing.
   - **libgit2** — Git is a central capability requiring fine-grained control,
     so Casper links libgit2 directly (via an in-house `CasperGit` wrapper)
     rather than depending on an external `git` binary.
   - **arm64-only** (Apple Silicon). No universal binary.
   - Release builds optimize for size: `-Osize`, LTO, symbol stripping.
4. **No notarization** in the distribution pipeline.

### Dependency policy (need → solution)

| Need | Solution | Kind |
|---|---|---|
| CLI argument parsing | **swift-argument-parser** (Apple) | external (allowed) |
| Git / worktree / diff ops | **libgit2** behind in-house `CasperGit` wrapper (`git_worktree_*`, `git_diff`, `git_status`) — **no external `git` binary** | external (allowed) |
| Terminal engine | **GhosttyKit** (libghostty XCFramework) | external (allowed) |
| Agent-state socket | `Network.framework` over a Unix domain socket | system |
| Persistence | `Codable` + `FileManager` | system |
| Notifications | `UserNotifications` | system |
| Browser | `WebKit` / `WKWebView` (no Chromium) | system |
| Diff coloring | `AttributedString`; +/- coloring only in v1 (no highlighter lib) | system |

The binary size is dominated by the libghostty XCFramework; Casper's own code is
small. libgit2 is statically linked (arm64). arm64-only keeps the native blobs
unduplicated.

## 3. Architecture Overview

### 3.1 Locked decisions

- **Embedding:** GhosttyKit / libghostty-spm, **version pinned**, isolated behind
  a single adapter module (`CasperGhostty`) because the libghostty embedding API
  is not yet stable. A version bump touches only that module.
- **Process model: in-process.** libghostty surfaces and their PTYs live inside
  the Casper process (same model as the Ghostty app). If Casper quits or crashes,
  running agents die — accepted trade-off. On relaunch the workspace/layout is
  restored; terminals start with fresh PTYs.
- **UI stack:** SwiftUI for chrome/sidebar/diff/browser; targeted AppKit
  (`NSViewRepresentable`, responder chain) to host Ghostty surfaces and handle
  fine-grained keyboard/focus.
- **Single binary:** one executable is both the GUI app and the CLI.
- **v1 agent:** Claude Code only.

### 3.2 Module boundaries (Swift packages / targets)

| Module | Responsibility | Depends on |
|---|---|---|
| **CasperGit** | Thin in-house Swift wrapper over the **libgit2** C API (module map). Exposes only the operations Casper needs: worktree add/list/prune/lookup, diff, status, branch/base resolution. We own this API. | libgit2 |
| **CasperCore** | Models, `SessionStore`, `AgentStateStore` (state machine), `WorktreeManager`, `PortAllocator`, `AgentAdapter` protocol. Pure Swift, fully testable, **no UI**. | CasperGit |
| **CasperGhostty** | `GhosttyRuntime`: wraps GhosttyKit, owns surface lifecycle, splits/tabs. The **only** module touching the unstable API. | GhosttyKit |
| **CasperAgents** | Claude Code adapter + generation of the hooks `settings.json`. | CasperCore |
| **CasperUI** | SwiftUI views (sidebar, chrome, diff, browser) + AppKit bridges. | CasperCore, CasperGhostty |
| **CasperCLI** | CLI subcommand dispatch built on **swift-argument-parser**. | CasperCore |
| **Casper** (app target) | Wiring, window, app lifecycle, mode dispatch (GUI vs CLI). | all |

Rationale: instability (libghostty), Git specifics (libgit2), and agent
specificity (Claude Code) are each confined to one module, so churn stays local.

## 4. Single Binary: GUI + CLI

The bundle executable inspects how it was invoked:

- No subcommand → **GUI mode** (launches the app).
- A recognized subcommand → **CLI mode** (`casper hooks …`, `casper open …`,
  `casper worktree …`), runs, then exits.

CLI parsing uses **swift-argument-parser**; the GUI/CLI fork happens before the
`ParsableCommand` tree is engaged (empty argv → GUI).

`casper` is **not installed globally** — no shim on the user's `PATH`. It only
needs to be reachable inside terminals Casper opens, so the app **prepends its
own executable directory to `PATH`** in every terminal surface's environment
(alongside the hook env vars, see §7 and §9). Claude Code hooks therefore invoke
the relative command `casper hooks feed`, which resolves only within Casper's
terminals. No separate hook binary is shipped, and nothing pollutes the user's
system.

## 5. Data Model

```
Session
 └─ [Workspace]
     ├─ id, name
     ├─ repoPath, worktreePath, branch
     ├─ agentState: AgentState        // idle | running | waiting | done | error | unknown
     ├─ todos: [Todo]                 // from Claude Code TodoWrite hook
     ├─ pendingNotification: Bool
     ├─ portBase: Int                 // base of a reserved 10-port block; env CASPER_PORT
     └─ layout: LayoutNode

LayoutNode =
   | Split(orientation: h|v, children: [LayoutNode], ratios: [Double])
   | TabGroup(surfaces: [Surface], activeIndex: Int)

Surface =
   | Terminal(cwd, command?)          // Ghostty surface; command defaults to the user's shell (no agent auto-run)
   | Browser(url)                     // WKWebView
   | Diff(target)                     // git diff vs base/HEAD

Todo = { content, status: pending|in_progress|completed }
```

Free-form layout: splits may nest arbitrarily; each leaf is a tab group holding
one or more surfaces (model close to Ghostty).

## 6. Sidebar

One row per workspace, grouped by repository. Each row shows:

- **state badge** — running ● / waiting ◐ / done ✓ / error ✕ / idle ○
- **name**
- **Git branch / worktree** label
- **progress** — `completed / total` from the todo list (e.g. `3/7`), plus the
  current `in_progress` task label
- **pending-notification** dot

## 7. Agent State & Progress (core mechanism)

```
Claude Code (inside a Ghostty surface)
   │  hooks: Stop / Notification / SessionStart / PostToolUse:TodoWrite
   ▼
`casper hooks feed`  (reads hook JSON on stdin; reads $CASPER_SOCKET,
                $CASPER_WORKSPACE_ID from the surface env)
   │  JSON {workspace, event, payload}  →  Unix domain socket
   ▼
AgentStateStore  (per-workspace state machine + todo list)
   │
   ├─► Sidebar (badge, progress, notification dot)
   └─► UserNotifications  (if workspace unfocused & state ∈ {waiting, done})
```

- **State** derives from `SessionStart` (→ running/idle), `Notification`
  (→ waiting, carries a status message), `Stop` (→ done).
- **`unknown` and `error` states are produced by the socket/heartbeat layer, not
  the pure reducer.** The `AgentStateReducer` (Plan 1 / CasperCore) only maps the
  four incoming hook events above; it cannot detect "no hooks ever arrived" (a
  hookless agent stays `idle`) or a crashed hook pipe. Detecting those — emitting
  `unknown` on a heartbeat timeout and `error` on a broken socket — is the
  responsibility of the socket owner in **Plan 3 (CLI + Agents)**. This is a
  deliberate, documented deferral, not a gap in the core.
- **Progress** derives from `PostToolUse` filtered on `TodoWrite`: the payload's
  `todos[]` (each with `content` + `status`) is stored per workspace;
  progress = `completed / total`, current = the `in_progress` item.
- Casper **never launches an agent itself**; the user runs Claude Code manually
  in a terminal surface. The hook plumbing is installed **once, globally**,
  into the user-level `~/.claude/settings.json` (via `casper hooks setup`, or
  at app startup) — **not per worktree**. The Claude Code adapter merges
  Casper's hooks (which call `casper hooks feed`) into that file, preserving
  the user's other settings. Although the hook is declared globally, its
  command is the **relative** `casper hooks feed`: **every terminal surface**
  exports `CASPER_SOCKET` + `CASPER_WORKSPACE_ID` + `CASPER_PORT` (see §9) and
  prepends the `casper` binary's directory to `PATH` (see §4), so
  `casper hooks feed` resolves **only** inside Casper's terminals. In any
  other terminal `casper` is not on `PATH`, so the global hook is simply not
  found — an accepted trade-off of the relative command. So the moment
  the user runs Claude Code there, hooks fire and state/progress flow.
- Until an agent runs, the workspace state is simply `idle`.
- **Fallback:** an agent with no hooks (or silent hooks) yields state `unknown`;
  never blocking.

## 8. Worktree Management

`WorktreeManager` drives libgit2 through the `CasperGit` wrapper (no external
`git` binary):

- create worktree (`git_worktree_add`, choose repo + branch/base), list
  (`git_worktree_list`), remove (`git_worktree_prune`)
- detect the base repository, detect dirty/locked states (`git_status`,
  `git_worktree_validate`)
- surface clear errors in the UI (e.g. branch already checked out) — never crash

Creating a workspace = creating a worktree, then opening a **plain Ghostty
terminal** in its folder. Casper's Claude Code hooks are installed globally,
once (§7) — not per workspace. No agent is spawned; the user launches Claude
Code manually if/when they want.

## 9. Port Reservation

Each workspace reserves a **contiguous block of 10 network ports** so the same
app can run once per worktree without collisions (a per-worktree port block).

- **`PortAllocator`** (in CasperCore) assigns the first free block from a
  configurable range (default `40000–49990` → ~1000 workspaces). The assigned
  `portBase` is stored on the workspace, **persisted** in `session.json`, so a
  workspace keeps its block across restarts; the block is released when the
  workspace is removed.
- **Environment exposure**, injected into **every terminal surface** of the
  workspace (alongside the hook env vars):
  - `CASPER_PORT` — base of the block
  - reserved range is `CASPER_PORT … CASPER_PORT+9`; optionally
    `CASPER_PORT_0 … CASPER_PORT_9` for convenience.
- **Logical reservation only**: Casper hands out non-overlapping
  numbers between workspaces but does not OS-bind the ports — no guarantee a port
  is system-wide free, only that blocks never overlap across workspaces.

## 10. Persistence

`SessionStore` serializes the full `Session` to
`~/Library/Application Support/Casper/session.json` via `Codable`, **debounced**
on each mutation. On relaunch:

- workspaces, layout tree, and every surface descriptor are recreated;
- **terminals** get a fresh PTY (plain shell in the worktree); no agent is
  auto-started. Hooks are global (§7), installed once — not re-installed per
  terminal or per relaunch;
- **browser** surfaces reload their URL;
- **diff** surfaces reload their target;
- each workspace's reserved `portBase` is restored as-is (no reallocation).

Terminal scrollback is not restored (in-process PTYs die with the app).

## 11. Diff Viewer & Browser

- **Diff:** SwiftUI surface backed by libgit2's `git_diff` API (structured
  hunks/lines, working tree vs base/HEAD) — no text parsing. Per-file
  navigation, +/- line coloring via `AttributedString`. Read-only in v1. No
  external highlighter.
- **Browser:** `WKWebView` surface (address bar, reload), aimed at previewing a
  `localhost:PORT` app started by the agent. No Chromium.

## 12. Error Handling & Risks

| Risk | Mitigation |
|---|---|
| libghostty API instability | All access behind `GhosttyRuntime`; pinned version; a bump touches one module |
| Worktree op fails (branch checked out, dirty tree) | Clear UI error, no crash |
| PTY dies | Surface marked closed, restartable |
| App crash | Agents lost (accepted); relaunch restores layout, surfaces start cold |
| Agent without hooks | State `unknown`, non-blocking |
| Binary size creep | Three justified externals only (GhosttyKit, swift-argument-parser, libgit2 static); arm64-only; `-Osize` + LTO + strip |

## 13. Testing Strategy

- **Unit:** `WorktreeManager` (against temporary git repos), `AgentStateStore`
  (state machine + todo aggregation), hook-event parsing, `SessionStore`
  round-trip, `PortAllocator` (non-overlapping blocks, reuse after release).
- **Integration:** end-to-end agent adapter driven by a **fake agent** that emits
  hook events to the socket.
- **Manual (checklist):** terminal rendering, keyboard/focus, notifications —
  hard to automate.

## 14. v1 Scope

**In:** worktree=workspace model, free-form splits/tabs layout, terminal +
browser + diff surfaces, per-workspace 10-port reservation (`CASPER_PORT`),
Claude Code state & todo-progress via hooks, enriched sidebar, full session
persistence, single GUI+CLI binary, arm64-only build.

**Out (later):** persistent session daemon (agents surviving app restart),
multi-agent orchestration, additional agent adapters (Codex, Gemini), editable
diffs, notarized distribution.

## 15. Open Questions

None blocking. To confirm during implementation planning:

- Exact Claude Code `settings.json` hook shape and stdin payload schema per hook
  (`Stop`, `Notification`, `SessionStart`, `PostToolUse`) — verify against the
  installed Claude Code version.
- **Resolved:** hooks go in the user-level `~/.claude/settings.json` (global),
  installed once — not in any per-worktree/project file, so the user's repo is
  never touched (see §7).
