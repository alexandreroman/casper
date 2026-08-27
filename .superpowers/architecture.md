# Casper — Architecture & Foundation

Cross-cutting design that applies across every theme. Module-specific design
lives in `themes/`; implementation progress lives in `status.md`. The original
per-milestone specs and completed plans are recoverable from Git history (they
were tracked under the now-removed `docs/superpowers/` tree before being
distilled here).

## Vision

A native macOS app that embeds **libghostty** to give each **Git worktree** a
dedicated terminal workspace, specialized for running code agents (Claude Code,
OpenAI Codex CLI, and opencode). It surfaces each agent's live state and task
progress in a sidebar, and bundles a native browser and diff viewer.
Distributable as a self-contained `Casper.app` from GitHub Releases (or from
source), **no Apple notarization**. The bundle is not cosmetic: a GUI app users
double-click expects one, Sparkle updates a `.app` delivered as a top-level
`.zip`, and `UNUserNotificationCenter` refuses to register without a valid
bundle identifier — a bare executable cannot post a notification at all (see
[[unusernotificationcenter-unbundled-abort]]).

## Hard constraints

1. **Native & performant** — macOS-native UI; GPU-accelerated terminal rendering
   via libghostty.
2. **Prefer built-in macOS frameworks** over third-party code.
3. **Minimum dependencies** — only five external deps (GhosttyKit,
   swift-argument-parser, libgit2 behind the in-house `CasperGit`,
   HighlightSwift for diff syntax highlighting, and Sparkle for auto-update);
   everything else uses system frameworks. See [[dependency-policy]] for the
   full rule, rationale, and the arm64 / `-Osize` build stance.
4. **No notarization.**

## Locked decisions

- **Embedding:** GhosttyKit / libghostty-spm, **version pinned**, isolated
  behind the single `CasperGhostty` module (the embedding API is unstable — a
  bump touches only that module). See [[ghosttykit-pin]].
- **Process model: in-process.** Surfaces and their PTYs live in the Casper
  process; if Casper quits, running agents die (accepted). Relaunch restores the
  layout with fresh PTYs.
- **UI stack:** SwiftUI for chrome, sidebar and browser; targeted AppKit
  (`NSViewRepresentable`, responder chain) to host Ghostty surfaces and to draw
  the diff, which is one TextKit 2 text document rather than a view tree.
- **Single binary:** one executable is both the GUI app and the CLI. The fork
  routes on argv *shape*, not vocabulary (`LaunchMode.detect`): empty argv →
  GUI; a first argument starting with `-` → GUI (it is an AppKit launch flag),
  except `-h`/`--help`/`--version`; anything else → CLI, where an unrecognized
  word fails with ArgumentParser's own error rather than silently opening a
  window.
- **v1 agents:** Claude Code, OpenAI Codex CLI, and opencode, all through the
  same agent-agnostic `casper` CLI. Each has its own terminal-scraping rule set,
  and all of them are applied to every surface — detection cannot tell which
  agent occupies a terminal, so it aggregates rather than choosing.

## Module boundaries

| Module            | Responsibility                                                                                                   | Theme                     |
| ----------------- | ---------------------------------------------------------------------------------------------------------------- | ------------------------- |
| **CasperGit**     | Thin wrapper over the libgit2 C API: worktrees, diff, status, branch/base                                        | `themes/git-worktrees.md` |
| **CasperCore**    | Models + `LayoutTree`, `SessionStore`, `WorktreeManager`, `PortAllocator`, `RepoConfig`, agent detection + integration probing, control channel. Pure Swift, no UI | `themes/core.md`          |
| **CasperGhostty** | `GhosttyRuntime`: wraps GhosttyKit, owns surface lifecycle + splits. The only module touching the unstable API   | `themes/terminal.md`      |
| **CasperAgents**  | Per-surface environment injection (`CASPER_WORKSPACE_ID`, `CASPER_CONTROL_SOCKET`, ports) for Casper terminals   | `themes/cli-agents.md`    |
| **CasperCLI**     | `casper` subcommand dispatch (swift-argument-parser)                                                             | `themes/cli-agents.md`    |
| **CasperUI**      | SwiftUI sidebar, chrome and browser, the AppKit diff renderer and Ghostty bridges; owns the window, the app lifecycle and all startup wiring | `themes/app-ui.md`        |
| **Clibgit2**      | `.systemLibrary` target binding libgit2 via Homebrew + pkg-config; no Swift code of its own                       | `themes/git-worktrees.md` |
| **CSigbusGuard**  | A C shim installing a `SIGBUS` handler around libgit2 diff, turning an mmap-truncation fault into a thrown error  | `themes/git-worktrees.md` |
| **casper** (exe)  | The single binary. `Sources/casper/main.swift` is a handful of lines: `LaunchMode.detect` → `CasperUI.runApp()` or `CasperCommand.main()` | all                       |

Rationale: instability (libghostty) and Git specifics (libgit2) are each
confined to one module, so churn stays local. Agent specifics are split on
purpose: the rule sets and the integration probe are pure logic and live in
`CasperCore`, while `CasperAgents` holds only what a terminal needs in its
environment.

## Data model (canonical)

```text
Session
 ├─ selectedWorkspaceID: UUID?
 ├─ dismissedAgentReminders: Set<String>  // encoded sorted, so an idle session is byte-stable
 ├─ lastNewSpaceLocation: String?         // parent folder the "New Space…" panel reopens at
 └─ [Space]                          // a folder, Git or not (see themes/space-project.md)
     ├─ id, name, folderPath
     ├─ isGitRepo: Bool                   // runtime-only, never persisted
     ├─ isCollapsed: Bool
     └─ [Workspace]
         ├─ id, name, kind: primary | linked
         ├─ worktreePath, branch, baseBranch
         ├─ agentState: working | blocked | idle | done | unknown | error
         ├─ todos: [Todo{content, status: pending|in_progress|completed}]
         ├─ pendingNotification: Bool
         ├─ pendingNotificationMessage: String?   // body of the pending notification
         ├─ infoMarkdown: String?                 // latest `casper info set` message; transient
         ├─ infoUnread: Bool                      // drives the info button's pulse; transient
         ├─ portBase: Int                         // 10-port block; env CASPER_PORT if linked
         ├─ layout: LayoutNode
         ├─ inspector: InspectorState             // right panel: collapsed, tab, browser, width
         ├─ lastUsedEditor: EditorKind?           // vscode | intellijIdea | xcode
         └─ lastUsedScript: String?               // last `.casper.json` command run here

LayoutNode = Split(orientation, children, ratios) | Leaf(Surface)
Surface    = id + fontSize: Float? + kind: Terminal(cwd) | Browser(url)
```

The diff view is **not** a layout-tree surface kind — it lives in the
per-workspace inspector panel (`Workspace.inspector`), alongside the inspector
browser. `LayoutNode.tabGroup` survives only as a legacy-decode migration path
(older `session.json` folds into leaves), not a live case.

The **Space** layer and `kind`/`baseBranch` shipped with CasperUI UI-2
(`themes/space-project.md`); the once-planned derived `diffStat` is **dropped**
(decision 2026-07-06). Persistence: `SessionStore` serializes the whole tree to
`~/Library/Application Support/Casper/session.json` (`Codable`, debounced);
terminals restart cold, browser/diff surfaces reload their target, `portBase` is
restored as-is.

## Risks & mitigations

| Risk                                          | Mitigation                                                       |
| --------------------------------------------- | ---------------------------------------------------------------- |
| libghostty API instability                    | All access behind `GhosttyRuntime`; pinned version               |
| Worktree op fails (branch checked out, dirty) | Clear UI error, never crash                                      |
| PTY dies                                      | Surface marked closed, restartable                               |
| App crash                                     | Agents lost (accepted); relaunch restores layout cold            |
| Agent never calls the CLI                     | State inferred from the terminal; `unknown` only when unreadable |
| Binary size creep                             | Five justified externals only; arm64-only; `-Osize` + strip      |
| libgit2 diff faults on a truncated mmap       | `CSigbusGuard` turns the `SIGBUS` into a thrown error            |
| Main thread blocked long enough to freeze the UI | DEBUG-only `MainThreadHangWatchdog` samples and reports it    |
| Corrupt or incompatible `session.json`        | `SessionStore` self-heals by discarding it rather than failing   |
| libgit2 unpinned in brew and CI               | Unmitigated — a brew bump can change diff behaviour underfoot    |

## Testing strategy

- **Unit (XCTest):** `WorktreeManager`, control protocol/targeting, the CLI
  command builders + JSON output, `SessionStore` round-trip, `PortAllocator`.
  Needs the full Xcode toolchain — see [[test-toolchain]].
- **Integration:** the control channel end to end over a real socket, and a
  live libghostty surface driven by real key events (`RealSurfaceHarness`).
- **Manual:** terminal rendering, keyboard/focus, notifications — via the
  `debug-casper` harness (`themes/debug.md`).

## v1 scope

**In:** worktree=workspace; free-form terminal panes; a per-workspace inspector
panel carrying the browser and the diff; a 10-port reservation per workspace;
agent state + todo progress in an enriched sidebar, with notifications and Dock
attention; a workspace info panel publishing Markdown into a toolbar popover;
per-repository `.casper.json` scripts with `setup`/`teardown` hooks; merge-and-
close and delete; Open in Editor; agent-integration detection; session
persistence; in-app auto-update; a single GUI+CLI binary, arm64-only.

**Out (later):** persistent daemon (agents surviving restart), multi-agent
orchestration, editable diffs, notarized distribution.
