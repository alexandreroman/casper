# Theme: App & UI (CasperUI)

**Module:** CasperUI · **Status:** ✅ **UI-1..UI-5 built** (app shell + wiring;
Space-grouped sidebar + linked Git worktrees; recursive splits/tabs; WKWebView
browser surface; read-only diff viewer). Pending: a live GUI verification pass
(see `../status.md`).

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
  `HSplitView`/`VSplitView`; a tab group shows a Ghostty-style tab bar (flush
  full-height segments sharing the width equally, centered titles, the active
  tab lit and inactive tabs dimmed from a fixed dark neutral chrome — no accent
  color; each tab has a leading hover-revealed `×` close button; a trailing `+`
  menu) and renders **only its active surface**. Deriving the tab shades from the
  live terminal background (as Ghostty does) is a deferred follow-up — Casper does
  not yet read the libghostty background color. Inactive surfaces stay alive in a persistent view cache keyed
  by `Surface.id` (their PTYs keep running; libghostty reads the PTY independently
  of rendering) and re-attach on re-selection. Rendering only the active surface
  avoids overlapping libghostty `CAMetalLayer`-backed terminals, which ignore
  SwiftUI `.opacity` and would occlude one another. The cache also makes a
  terminal's PTY survive split/collapse/reorder restructuring (surface identity is
  anchored solely on `Surface.id`). Persisted
  split `ratios` are **not** applied by the native split views in v1 (they open
  evenly; ratios are retained in the model for a future custom-split renderer). Pure `LayoutTree` tree operations
  (`insertTab`/`split`/`closeSurface`, flat sibling insertion when the parent
  orientation matches) live in CasperCore and are heavily tested. libghostty
  `newTab`/`newSplit`/`closeTab` route through a `LayoutActionHandler` installed on
  the runtime to the **focused** workspace (focus tracked via the surface's
  first-responder callback). Closing the last surface closes the workspace
  non-destructively (linked → `removeWorkspace`, primary → `removeSpace`). `.diff`
  leaves render a placeholder until UI-5 (terminals and browsers are live — see
  the UI-4 bullet).
- **UI-4 — ✅ built.** A `WKWebView` browser surface (address bar with bare-host
  normalization, back/forward/reload) renders `.browser` layout leaves, created
  via the tab-bar "+" menu (New terminal / New browser). The web view lives in the
  persistent surface-view cache keyed by `Surface.id` (generalized from UI-3 to
  hold any `NSView`), so it survives layout restructuring like terminals; its URL
  is persisted via the address bar (link-follow write-back through
  `WKNavigationDelegate` is a deferred follow-up).
- **UI-5 — ✅ built.** A read-only diff surface renders `.diff` layout leaves over
  CasperGit's `diffWorkdirToHead()`: per-file sections (path + status, binary
  files noted), hunk headers, and monospaced line rows colored by kind
  (green addition / red deletion / neutral context) with old/new line-number
  gutters and a `+`/`-`/space prefix cue. Computed on open + a refresh button
  (no live auto-refresh in v1); created via the tab-bar "+" menu (New diff).

## Next action

**All five CasperUI sub-projects (UI-1..UI-5) are built.** Remaining cross-cutting
work outside this milestone: the Space `+/−` diff summary
(`space-project.md`, needs branch-vs-merge-base counts), Space rename, and a
**live GUI verification pass** on a real desktop (the headless sandbox cannot
materialize the SwiftUI detail hierarchy, so splits/tabs, browser navigation, and
the diff surface need a live check).
