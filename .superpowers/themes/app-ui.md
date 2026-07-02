# Theme: App & UI (CasperUI)

**Module:** CasperUI · **Status:** ◐ **UI-1 built** (app shell + minimal sidebar
+ one terminal + startup wiring); UI-2…UI-5 remain (see `../status.md`) · **This
is the current milestone.**

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
- **UI-2** — multi-workspace creation via Git worktrees + Space grouping.
- **UI-3** — recursive splits/tabs `LayoutNode` composition.
- **UI-4** — `WKWebView` browser surface.
- **UI-5** — diff viewer (SwiftUI over libgit2 `git_diff`).

## Next action

**UI-2**: multi-workspace via Git worktrees + Space grouping. Note the
`space-project.md` plan already assumes the sidebar exists; sequence UI-2 and the
Space work deliberately.
