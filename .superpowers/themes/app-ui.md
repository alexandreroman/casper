# Theme: App & UI (CasperUI)

**Module:** CasperUI · **Status:** ◐ **UI-1 & UI-2 built** (app shell + startup
wiring; Space-grouped sidebar + linked Git worktrees); UI-3…UI-5 remain (see
`../status.md`) · **This is the current milestone.**

The SwiftUI app that turns the built modules into the real product. Delivered as
five sub-projects (UI-1…UI-5), each with its own spec → plan → build cycle. The
diff viewer (UI-5) depends on CasperGit `git_diff` (`git-worktrees.md`); the
recursive splits/tabs layout (UI-3) depends on Ghostty layout composition
(`terminal.md`).

## Design

- **Sidebar** — one row per workspace, grouped by repository (the Space, see
  `space-project.md`). Each row: state badge (running ● / waiting ◐ / done ✓ /
  error ✕ / idle ○), name, Git branch/worktree label, todo progress
  (`completed/total` + current `in_progress` label), pending-notification dot,
  and the `+/−` diff summary.
- **Layout composition** — arbitrary nested splits and tab groups; leaves are
  terminal, browser, or diff surfaces. Consumes the decoded Ghostty split/tab
  actions.
- **Diff viewer** — a SwiftUI surface backed by libgit2's `git_diff` (structured
  hunks/lines, working tree vs base/HEAD). Per-file navigation, +/- line coloring
  via `AttributedString`. Read-only in v1, no external highlighter.
- **Browser** — a `WKWebView` surface (address bar, reload), aimed at previewing a
  `localhost:PORT` app started by the agent. No Chromium.
- **Wiring** — connects `HookSocketServer.onMessage` → `AgentStateStore`, installs
  hooks at startup, injects the bundle exec dir into surface env, and runs the
  heartbeat timer (all detailed in `cli-agents.md`).

## Sub-projects

- **UI-1 — ✅ built.** App shell (SwiftUI `App` scene + `NSApplicationDelegateAdaptor`,
  the existing AppKit `NSMenu` preserved), `@MainActor @Observable AppModel` as the
  single state owner/bridge, `NavigationSplitView` with empty state, "Add folder…"
  (adopt any folder — Git or not, multiple allowed), one live terminal per
  workspace, and all startup wiring (hooks install, hook socket → agent-state
  reducer, per-surface env, heartbeat timer, session persistence, `#if DEBUG`
  debug bridge). No Git worktree creation. Renders only the single-terminal layout.
- **UI-2 — ✅ built.** The `Space` level (`Session → Space → Workspace`;
  `repoPath` moved up to `Space.folderPath`; `Workspace` gained
  `kind: primary|linked` and `baseBranch`). Opening a folder builds a Space (Git
  or not — non-Git folders are degenerate Spaces with one primary workspace and
  no worktree creation); a per-Space "+" creates a **linked** workspace as a new
  branch + `git worktree` under `<folder>/.casper/worktrees/<branch>` (with
  `.casper/` added to `.git/info/exclude`). The sidebar is grouped by Space in
  collapsible sections; removal is non-destructive (drop a linked workspace, or a
  whole Space, leaving worktrees/branches on disk); a degenerate Space is promoted
  to Git on the heartbeat when its folder gains a `.git`. The `+/−` diff summary
  is deferred to UI-5.
- **UI-3 — ✅ built.** Recursive `LayoutNode` composition: splits render as native
  `HSplitView`/`VSplitView`, tab groups as a tab bar over a `ZStack` keeping
  inactive surfaces mounted (PTYs alive). Pure `LayoutTree` tree operations
  (`insertTab`/`split`/`closeSurface`, flat sibling insertion when the parent
  orientation matches) live in CasperCore and are heavily tested. libghostty
  `newTab`/`newSplit`/`closeTab` route through a `LayoutActionHandler` installed on
  the runtime to the **focused** workspace (focus tracked via the surface's
  first-responder callback). Closing the last surface closes the workspace
  non-destructively (linked → `removeWorkspace`, primary → `removeSpace`). Only
  terminal leaves are created; browser/diff leaves render a placeholder until
  UI-4/UI-5.
- **UI-4** — `WKWebView` browser surface.
- **UI-5** — diff viewer (SwiftUI over libgit2 `git_diff`).

## Next action

**UI-4**: a `WKWebView` browser surface (address bar, reload) as a new
`Surface.Kind` leaf in the layout, aimed at previewing a `localhost:PORT` app.
The recursive `LayoutNodeView` from UI-3 already routes non-terminal leaves to a
placeholder — UI-4 replaces that placeholder for `.browser`.
