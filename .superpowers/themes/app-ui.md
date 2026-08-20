# Theme: App & UI (CasperUI)

**Module:** CasperUI · **Status:** ✅ **UI-1..UI-5 built** (app shell + wiring;
Space-grouped sidebar + linked Git worktrees; recursive splits/tabs; WKWebView
browser surface; read-only diff viewer). The live GUI verification pass is
complete (see `../status.md`).

> **Superseded:** the tabbed surface model below (UI-3) is replaced by a
> **tmux-style pane layout** — no tabs, one surface per pane, a right-click pane
> menu for splits, and a redesigned window toolbar/sidebar. See `../status.md` →
> "Surface layout — tmux-style panes". The UI-3 tab-bar description here is kept
> for history.

The SwiftUI app that turns the built modules into the real product. Delivered as
five sub-projects (UI-1…UI-5), each with its own spec → plan → build cycle. The
diff viewer (UI-5) depends on CasperGit `git_diff` (`git-worktrees.md`); the
recursive splits/tabs layout (UI-3) depends on Ghostty layout composition
(`terminal.md`).

## Design

- **Sidebar** — one row per workspace, grouped by repository (the Space, see
  `space-project.md`). Each row: state badge (working ● / blocked ◐ / done ✓ /
  error ✕ / idle ○), name, Git branch/worktree label, todo progress
  (`completed/total` + current `in_progress` label), and a pending-notification
  dot.
- **Dock attention** — the sidebar dot's out-of-app counterpart, owned by
  `DockAttention` (a `DockAttentionPresenting` seam on `AppModel`, over a
  `DockAttentionBackend` seam on `NSApp`, so both the wiring and the latch are
  testable without a running application). Arming a workspace's attention bubble
  starts a `.criticalRequest` Dock bounce — one that keeps bouncing until Casper
  is activated, not a single hop — and refreshes a Dock badge carrying the
  number of workspaces with an unread notification across every Space.

  **Attention is never requested while Casper is the active application.** That
  is AppKit's own contract for `requestUserAttention`, and following it is what
  keeps the latch honest: a request made in front bounces nothing, yet the
  request id it stores would be released by no one (`applicationDidBecomeActive`
  does not fire for an app that never left the front) and would swallow the
  next real bounce. The arming edge itself is not focus-gated (a notification
  for a workspace that is merely *not selected* arms while the window is key),
  so this rule lives in `DockAttention`, not in its caller.

  The two clear on different events, deliberately. The **bounce** starts only on
  the edge that arms a bubble, never on a later focus loss: the badge already
  carries that unread, and a window the user just left is not news. It is
  released on `applicationDidBecomeActive` (macOS has stopped it by then; this
  frees the request id so the next notification starts a fresh one), on
  `applicationDidResignActive` (nothing requested in front may outlive the
  activation), and whenever the unread count reaches zero, so a badge-free Dock
  icon can never be left bouncing. The **badge** survives activation and only
  counts down as each workspace is individually cleared — by focusing it
  (`clearNotificationForFocusedWorkspace`), by the agent resuming work
  (`done → working`), or by the workspace being deleted or closed.
- **Layout composition** — arbitrary nested splits and tab groups; leaves are
  terminal, browser, or diff surfaces. Consumes the decoded Ghostty split/tab
  actions.
- **Diff viewer** — a read-only surface backed by libgit2's `git_diff`
  (structured hunks/lines, working tree vs base/HEAD), rendered as **one TextKit
  2 text document**. The diff is flattened into flat text plus per-file and
  per-line spans, and AppKit draws everything on top of it: the row tints in the
  text view, the accent stripe, the line numbers and the `+`/`-` cue in an
  `NSRulerView` gutter, the pinned file header as an overlay that reads layout
  and never feeds back into it. **The text storage holds source text only** —
  numbers, cue and header band all live outside it — which buys three things at
  once: a copy yields clean code with no stripping anywhere, a selection cannot
  highlight a rendering artefact, and every display row of a wrapped line shares
  one leading edge (a cue in the text indented only the first of them). A
  truncated line's `… (line truncated)` marker is the one piece of commentary
  kept inside the text, deliberately: it is the only sign that a copy of that
  line is a prefix of the real one. Syntax colors are applied
  progressively per file
  (HighlightSwift), **color attributes only**, so a highlight landing mid-scroll
  cannot change a line height and shift the text under the reader.

  > **Superseded:** the original design — a SwiftUI surface with per-file
  > navigation, `+`/`-` line coloring via `AttributedString`, and no external
  > highlighter — no longer holds on either count. The external highlighter
  > arrived with the Claude Code color restyle
  > (`plans/diff-view-claude-code-colors.md`); the per-line SwiftUI view tree
  > was removed because it put the SwiftUI layout graph on the per-diff-line
  > path, which is exactly what the text document exists to avoid.
- **Browser** — a `WKWebView` surface (address bar, reload), aimed at previewing a
  `localhost:PORT` app started by the agent. No Chromium.
- **Inspector panel** — a collapsible right-side panel on the workspace detail
  view with two tabs (Browser | Diff), per workspace and persisted
  (`Workspace.inspector`). It reuses the browser and diff surfaces rather than
  replacing them. The `.diff` layout-leaf surface kind was **removed** — the
  diff view now lives **only** in the inspector; the `.browser` tmux-pane path
  still exists, `.diff` does not. See `../status.md` →
  "Right inspector panel" for the as-built model, chrome, and title-bar changes
  (globe button removed, panel toggle added, `+/−` summary opens the Diff tab).
- **Wiring** — starts the release control server (`casper` CLI → `AppModel`),
  injects the bundle exec dir + per-surface env into each terminal, and runs the
  `#if DEBUG` debug bridge (all detailed in `cli-agents.md`).

## Sub-projects

- **UI-1 — ✅ built.** App shell (SwiftUI `App` scene + `NSApplicationDelegateAdaptor`,
  the existing AppKit `NSMenu` preserved), `@MainActor @Observable AppModel` as the
  single state owner/bridge, `NavigationSplitView` with empty state, "Add folder…"
  (adopt any folder — Git or not, multiple allowed), one live terminal per
  workspace, and all startup wiring (the release control server, per-surface env,
  session persistence, `#if DEBUG` debug bridge). No Git worktree creation.
  Renders only the single-terminal layout.
- **UI-2 — ✅ built.** The `Space` level (`Session → Space → Workspace`;
  `repoPath` moved up to `Space.folderPath`; `Workspace` gained
  `kind: primary|linked` and `baseBranch`). Opening a folder builds a Space (Git
  or not — non-Git folders are degenerate Spaces with one primary workspace and
  no worktree creation), with **one Space per Git repository** — identity being
  the common `.git` directory every working tree of a repository shares. A folder
  that is a **linked worktree of a repository already open as a Space** is adopted
  into that Space as a linked workspace instead of becoming a Space of its own
  (nothing is created on disk, so no `setup` hook runs); conversely, opening a
  **repository whose worktrees are already open as Spaces** reunifies them into
  the Space it creates, moving those workspaces whole (ids, ports, layouts and
  live terminals unchanged) with each ex-primary becoming a linked workspace named
  after its branch. Re-adding a folder Casper already tracks only selects it; a
  per-Space "+" creates a **linked** workspace as a new
  branch + `git worktree` at a visible sibling of the repo folder,
  `<parent>/<repo>-<branch>` (outside the repo, so naturally untracked — no
  in-repo `.casper/worktrees/` and no `.git/info/exclude` entry; a `-2`/`-3`…
  suffix is used if the sibling name is taken). The sidebar is grouped by Space in
  collapsible sections; removal is non-destructive (drop a linked workspace, or a
  whole Space, leaving worktrees/branches on disk); a degenerate Space is promoted
  to Git when its folder gains a `.git` (detected live by the filesystem watcher,
  and once per Space at launch), and demoted back if the `.git` is removed. The
  per-workspace `+/−` diff summary is **dropped** (decision 2026-07-06) — see
  the "Next action" note below.
- **UI-3 — ✅ built.** Recursive `LayoutNode` composition: splits render as native
  `HSplitView`/`VSplitView`; a tab group shows a Ghostty-style tab bar (rounded
  "pill" tabs sharing the width equally, centered titles; the active tab a filled
  bordered pill and inactive tabs blended into a fixed dark neutral chrome — no
  accent color; each tab has a leading hover-revealed `×` close button and the
  whole pill is clickable; a trailing circular `+` menu) and renders **only its
  active surface**. One deferred follow-up: deriving the tab shades from the
  live terminal background (as Ghostty does — Casper does not yet read the
  libghostty background color). The `⌘N` switch shortcuts moved scope from tabs
  to **workspaces** and are wired: `AppModel.workspaceShortcutNumbers` assigns
  1–9 down the sidebar, `WorkspaceShortcutKeyMonitor` maps ⌘1–⌘9 by physical
  key code (so AZERTY works) into `selectWorkspace(atShortcutNumber:)`, and
  holding ⌘ for ≥250 ms reveals the number hints in the sidebar rows. Inactive
  surfaces stay alive in a persistent view cache keyed by `Surface.id` (their
  PTYs keep running; libghostty reads the PTY independently of rendering) and
  re-attach on re-selection. Rendering only the active surface
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
- **UI-5 — ✅ built.** A read-only diff surface over CasperGit's
  `diffWorkdirToHead()`: per-file sections (path + status, binary
  files noted), hunk headers, and monospaced line rows colored by kind
  (green addition / red deletion / neutral context) with old/new line-number
  gutters and a `+`/`-`/space prefix cue. Computed on open and **live-refreshed**:
  a native FSEvents watcher on the selected workspace's folder (debounced ~200 ms,
  `.git` + Git-ignored top-level dirs excluded) bumps an observable revision that
  both the diff surface and the title-bar `+/−` badge react to. Originally
  rendered as a `.diff` layout leaf (created via the tab-bar "+" menu); that
  surface kind was later **removed** — the diff view now lives **only** in the
  right inspector panel (`Workspace.inspector`). The rendering above is
  unchanged, just hosted by the inspector instead of a layout leaf.

  > **Superseded:** the per-line rendering described above (a `LazyVStack` of
  > per-file sections, one SwiftUI row per diff line, pinned `Section` headers)
  > is replaced by a single TextKit 2 text document, which also adds text
  > selection and copy. The diff computation, the FSEvents live refresh and the
  > reading experience are unchanged. See `../status.md` → "Diff renderer —
  > one TextKit 2 text document" for the as-built pipeline.

## Next action

**All five CasperUI sub-projects (UI-1..UI-5) are built** and have passed the live
GUI verification pass on a real desktop (splits/tabs, browser navigation, diff
surface). Remaining cross-cutting work outside this milestone: **Space rename**.
(The Space `+/−` per-workspace diff summary was **dropped** — decision
2026-07-06; the title-bar working-tree-vs-HEAD summary covers the need.)
