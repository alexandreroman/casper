# Casper — Implementation Status

The progress ledger: what is built, what is left, and what was decided against.

**The design and the as-built behaviour live elsewhere.**
[`architecture.md`](architecture.md) carries the foundation and `themes/` owns
one area each — how a thing works is described there, once, and when this file
disagrees with a theme the theme wins. One-off technical findings live in
`.claude/project-memory/`; the map is [`INDEX.md`](INDEX.md); plans still worth
keeping are in `plans/`.

Status legend: ✅ built · ◐ partial · ❌ not started.

## At a glance

All five modules are built, and Casper is a working product: a Space-grouped
sidebar over linked Git worktrees, tmux-style terminal panes, a right inspector
panel carrying the browser and the diff view, per-repository `.casper.json`
scripts, agent-state detection for three coding agents, and in-app auto-update.
`make build` and `make test` are green (1226 tests, 2 skipped, 0 failures —
measured 2026-08-25).

| Area                                 | Status | Design & as-built                                                    |
| ------------------------------------ | ------ | -------------------------------------------------------------------- |
| CasperCore                           | ✅     | [`themes/core.md`](themes/core.md)                                   |
| CasperGit (+ Clibgit2, CSigbusGuard) | ✅     | [`themes/git-worktrees.md`](themes/git-worktrees.md)                 |
| CasperCLI + CasperAgents             | ✅     | [`themes/cli-agents.md`](themes/cli-agents.md)                       |
| CasperGhostty                        | ✅     | [`themes/terminal.md`](themes/terminal.md)                           |
| CasperUI (UI-1…UI-5)                 | ✅     | [`themes/app-ui.md`](themes/app-ui.md)                               |
| Space (project)                      | ◐      | [`themes/space-project.md`](themes/space-project.md)                 |
| Agent-state detection                | ◐      | [`themes/agent-state-detection.md`](themes/agent-state-detection.md) |
| Agent integration detection          | ✅     | `themes/cli-agents.md` § Agent integration detection                 |
| Debug & observability (`#if DEBUG`)  | ✅     | [`themes/debug.md`](themes/debug.md)                                 |

The ◐ rows are the areas whose *design* is unfinished; open items sit under ✅
rows too. Everything outstanding is listed under [Remaining
work](#remaining-work).

## Shipped

Every line below is built and tested. This list only records that the feature
exists; the behaviour is in the area's theme doc.

**Workspaces & Spaces.** Space assembly from any folder (Git or not), one Space
per repository enforced in every direction — adoption, reunification, and
pulling in the repository of a worktree opened on its own (rooted at its main
working tree, refusing a bare repository or an unresolvable one outright rather
than falling back). Linked worktrees are created as visible siblings of the
repo, under a collapsible Space-grouped sidebar
with agent state, todo progress and a notification bubble, non-destructive
removal, and live Git promotion/demotion. Session persistence with
legacy-decode self-healing. Selection after a close follows
[`plans/workspace-close-selection.md`](plans/workspace-close-selection.md).

**Terminal & layout.** libghostty embedding end-to-end — keyboard, clipboard
(including untrusted-write confirmation), mouse and cmd+click URL opening,
`flagsChanged` press/release, scroll precision and momentum. A tmux-style
`LayoutNode` tree of splits and one-surface panes, with a pane context menu,
draggable dividers whose ratios persist, pane drag-and-drop, close-on-process
exit, and a re-seeded terminal when the last pane closes. Per-surface font size
persists. ⌘1–⌘9 select workspaces by physical key code (so AZERTY works), with
the numbers revealed in the sidebar after a ⌘ hold.

**Inspector panel.** A per-workspace, resizable, persisted right panel holding
the WKWebView browser and the read-only diff, opened and switched from the title
bar and the control channel. The diff is one TextKit 2 text document —
selectable and copyable as clean code — computed from libgit2's diff,
live-refreshed by two FSEvents watchers, and syntax-coloured progressively.

**Title bar & menus.** A branch/Space title chip, the `+ins −del` diff summary
button, the info-panel button, and Merge, Run Script and Editor chips (Merge
becomes Delete while Option is held). The Editor chip launches the worktree in
VS Code, IntelliJ IDEA or Xcode. Casper defines its whole menu bar through
SwiftUI `.commands` (with an AppKit resync for the File → Space retitle),
sharing one description of the workspace commands between the Space menu, the
Edit menu and the sidebar row menu.

**Scripts & lifecycle.** `.casper.json` `workspace.copyFiles`, on-demand named
commands (CLI, title-bar chip, sidebar submenu), and reserved `setup`/`teardown`
hooks with their child-exit ordering invariants. Closing or deleting a workspace
reports its steps in a window-modal progress sheet, one operation per workspace
at a time, with a failing hook surfaced but never blocking the destroy.

**Agents.** The agent-agnostic `casper` CLI
(`status`/`progress`/`notify`/`info`/`terminal`/`browser`/`diff`/`workspace`/
`run`) over the control channel, with per-surface environment injection; Casper
installs no hooks into any agent. The browser verbs drive the inspector
WKWebView for automation and debugging; sized and `--url` screenshots render in
a dedicated off-screen web view instead. Agent-state detection covers Claude
Code, Codex and opencode from three signal sources, behind a `casper status`
authority latch. Agent *integration* detection reports, per agent, whether its
CLI and the Casper plugin are present, current and approved, and reminds in the
sidebar — detect-and-link only, never writing another tool's configuration.

**Attention.** `blocked`/`done`/`error` raise a notification (`done` passive,
the other two active) with a per-workspace cooldown, a Dock bounce that lasts
until activation, and a Dock badge counting unread workspaces. The workspace
info panel renders `casper info set` Markdown through a native TextKit path,
with links routed to the workspace's own browser unless ⌘ is held.

**Packaging.** Sparkle auto-update against an EdDSA-signed appcast, the
`.github/workflows/release.yml` tag workflow publishing the `.app`, its
`.sha256`, a separate `.dSYM.zip` and the `appcast.xml` the feed resolves to,
and the macOS 26 Liquid Glass `AppIcon.icon` compiled by `actool` alongside the
legacy `.icns`.

**Developer tooling** (`#if DEBUG`, physically absent from `make release`). The
debug channel's ten verbs with stable surface addressing and `--target`, the
live-object memory census, the main-thread hang watchdog, and `--session`
isolation.

**Resource discipline.** Minimising, occluding or hiding the window stops both
FSEvents watchers, pauses the terminal render thread and suspends off-screen
browser media; agent detection polls at 250 ms visible / 1 s hidden and strides
non-selected workspaces.

## Remaining work

1. **Space rename** — the only outstanding feature. The Space model and sidebar
   grouping shipped with UI-2; nothing renames a Space (its sidebar menu offers
   "Remove Space" only). See `themes/space-project.md`.
2. **Agent-state detection deferrals** — a `.render`-driven trigger in place of
   the timer poll, option-B timeout authority release, per-surface status, and a
   real `error` signal alongside the agent-as-command `done`/`error` path. Those
   four, and four open questions — starting with whether current Codex still
   prints an interrupt affordance at all — are specified in
   `themes/agent-state-detection.md` § Deferred / out of scope and
   § Open questions.
3. **Diff highlight repaint** — the repaint is one synchronous main-thread burst
   and repaints every carried file, not only those whose text moved. The
   ordering fix that ended the observed freeze is in and covered by a test, but
   has **not** been confirmed live on an actively-edited worktree, which is the
   only setup that produced the freeze; the DEBUG-only
   `MainThreadHangWatchdog` stays wired until it has. See
   [[nstextstorage-attribute-run-order]].
4. **Standing limitations** — `WorktreeManager.remove` prunes a worktree without
   deleting its branch; its one production caller deletes the branch on the next
   line, so this only bites a second caller. libgit2 is unpinned in brew and CI.

Two visual passes still need a human, since agents cannot screenshot the SwiftUI
chrome: the `.casper.json` setup/teardown split lifecycle, and the info panel's
hover, pulse, link-cursor and link-routing behaviour. See
[[agent-visual-verification-limits]].

## Decided against

- **The per-workspace `+/−` diff summary** — the branch-vs-merge-base divergence
  badge designed for the Space sidebar row (decision 2026-07-06). The title
  bar's working-tree-vs-HEAD summary covers the need, so this is the intended
  behaviour rather than a stopgap. See [[space-diff-summary-dropped]].
- **A process-exit (`childExited`) `done`/`error` producer** and the authority
  release built on it. `onChildExit` is wired, but only to the script-hook
  runner, so `error` has no terminal-scraping producer — it is raised by a
  `setup` hook exiting non-zero, or explicitly by `casper status set error`. The
  *agent-as-command* surface this would need is technically reopened — the
  vendored libghostty does exec `command` — but has not been re-evaluated, and
  the shipped `--command` fix types into the existing login shell rather than
  exec'ing, so it does not create one. See `themes/agent-state-detection.md`
  § Process lifecycle.

## Superseded designs

These designs survive in `themes/` as history rather than as-built, recorded
here so a reader who meets the old wording knows which way it went. A fourth,
the Space `+/−` divergence badge, is retained for the record in
`themes/space-project.md` and filed under [Decided against](#decided-against).

- **Tabs → tmux panes.** UI-3's tabbed surface model, its tab bar and
  `insertTab` are gone; `LayoutNode` is `split | leaf`, every pane holds one
  surface, and `tabGroup` survives only as a legacy decoding key. The two
  follow-ups the tab bar carried — terminal-derived tab shades and per-tab ⌘N —
  went with it; ⌘N shipped instead as ⌘1–⌘9 over **workspaces**.
- **`.diff` and `.browser` layout leaves → the inspector panel.** The `.diff`
  surface kind was removed outright and `.browser` is reachable only through
  `Workspace.inspector.browser`; splits always create a terminal. Browser panes
  therefore do not exist, which retires the "WebKit swallows the pane
  right-click" follow-up.
- **Per-line SwiftUI diff rows → one TextKit 2 document.** The computation, the
  live refresh and the reading experience are unchanged; selection and copy are
  new. `DiffFileView`, `DiffLineRow`, `DiffFileHeaderBar` and `DiffFileMetrics`
  are gone.
