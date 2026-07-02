# Theme: App & UI (CasperUI)

**Module:** CasperUI · **Status:** ❌ not started — no module, **no plan written
yet** (see `../status.md`) · **This is the current milestone.**

The SwiftUI app that turns the built modules into the real product. Depends on
CasperGit `git_diff` (`git-worktrees.md`) and Ghostty layout composition
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

## Next action

**Write the CasperUI implementation plan** — it does not exist. The
`space-project.md` plan already assumes the sidebar exists, so this plan must come
first (or the two be sequenced deliberately).
