# Theme: App & UI (CasperUI)

**Module:** CasperUI · **Status:** ✅ **UI-1..UI-5 built** (app shell + wiring;
Space-grouped sidebar + linked Git worktrees; tmux-style pane layout; WKWebView
browser surface; read-only diff viewer). The live GUI verification pass is
complete (see `../status.md`).

The SwiftUI app that turns the built modules into the real product. Delivered as
five sub-projects (UI-1…UI-5), each with its own spec → plan → build cycle. The
diff viewer (UI-5) depends on CasperGit `git_diff` (`git-worktrees.md`); the
pane layout (UI-3) depends on Ghostty layout composition (`terminal.md`).

Several designs this doc once carried have been superseded — UI-3 shipped with
tab groups and now has none, UI-4's and UI-5's layout leaves moved into the
inspector panel, and UI-5's per-line rendering became one text document. Each is
marked with a `> **Superseded:**` note where the old wording sits. Outside those
notes, § Design describes the app that exists.

## Design

- **Sidebar** — one row per workspace, grouped by repository (the Space, see
  `space-project.md`). A row (`WorkspaceRow.swift`) leads with a fixed-width
  agent-state slot holding a **monochrome SF Symbol**: `working` a continuously
  spinning `arrow.triangle.2.circlepath`, `blocked` an `exclamationmark.circle`,
  `done` a `checkmark.circle`, `error` an `xmark.octagon`, and `idle`/`unknown`
  **nothing at all** — the slot still reserves its width so the following
  columns stay aligned as the state changes. Then a branch/folder Octicon, and
  `Workspace.branchLabel` as the row's primary text. Trailing: a
  pending-notification bubble, swapped for the ⌘1–⌘9 shortcut hint while ⌘ is
  held.

  Below that, and only when there are todos or something to say, a `ProgressBar`
  (completed ÷ total) and **one** caption line. `RowDisplayState` composes that
  caption, preferring the pending-notification message over the current
  `in_progress` todo label — the more urgent signal wins, and stays up until the
  notification clears — and falling back to `"Done"` once every todo is
  complete. There is no numeric `completed/total` text. Nothing in the row
  carries a hue: selection tints every glyph and label white on the accent pill,
  and that is the only colour involved.
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
  does not fire for an app that never left the front) and would swallow the next
  real bounce. The arming edge itself is not focus-gated (a notification for a
  workspace that is merely *not selected* arms while the window is key), so this
  rule lives in `DockAttention`, not in its caller.

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
- **Layout composition** — arbitrary nested splits, tmux-style, with **no tab
  groups**. Every leaf the app can create is a **terminal**: `Surface.Kind` also
  has a `.browser` case, but only the inspector builds one (see "Inspector
  panel"), and the diff view is not a surface kind at all. Consumes the decoded
  Ghostty split/tab actions, with `newTab` mapped to a right split.

  The pure tree operations live in `CasperCore/LayoutTree.swift` and are heavily
  tested: `split` (which inserts a flat sibling when the parent's orientation
  already matches, rather than nesting a second split), `closeSurface`, `move`
  (relocate a leaf elsewhere in the tree), and `dropZone` (map a point inside a
  pane to the edge-or-centre zone a drag would land in). The last two back pane
  **drag-and-drop** — `PaneDragAndDrop.swift` owns the grip, the drag session
  and the drop overlay, surfaced by `SurfaceHostView`/`SplitContainerView`; see
  [[intra-app-drag-pasteboard-type]]. There is no `insertTab` operation: tabs
  are gone.
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
  line is a prefix of the real one. Syntax colors are applied progressively per
  file (HighlightSwift), **color attributes only**, so a highlight landing
  mid-scroll cannot change a line height and shift the text under the reader.

  > **Superseded:** the original design — a SwiftUI surface with per-file
  > navigation, `+`/`-` line coloring via `AttributedString`, and no external
  > highlighter — no longer holds on either count. The external highlighter
  > arrived with the Claude Code color restyle (`DiffHighlighter.swift` +
  > `DiffLineStyle.swift`, whose tints are sampled from Claude Code's own diff
  > rendering); the per-line SwiftUI view tree was removed because it put the
  > SwiftUI layout graph on the per-diff-line path, which is exactly what the
  > text document exists to avoid.
- **Browser** — a `WKWebView` surface (address bar, reload), aimed at previewing
  a `localhost:PORT` app started by the agent. No Chromium.
- **Inspector panel** — a collapsible right-side panel on the workspace detail
  view with two tabs (Browser | Diff), per workspace and persisted
  (`Workspace.inspector`). It reuses the browser and diff surfaces rather than
  replacing them.

  **The inspector is the only home for both.** The `.diff` layout-leaf surface
  kind was removed outright, and `Surface.Kind.browser` is now reached only
  through `Workspace.inspector.browser`: splits always create a terminal
  (`PaneContextMenu`), there is no "New browser" menu item anywhere, and
  `AppModel.surfaceView(for:in:)` returns a view only for `case .terminal` — so
  a `.browser` leaf that did reach the layout tree would render as the black
  fallback rectangle `SurfaceHostView` paints when no view resolves. Such a leaf
  survives only as a legacy `session.json` decode; nothing in the app creates
  one.

  The panel has no tab control of its own. Everything that opens, closes or
  switches it lives in the title bar (see "Title bar" below) or arrives over the
  control channel — and the two have deliberately different semantics. Every
  title-bar control routes through `AppModel.toggleInspectorTab`: expand onto
  that tab when collapsed, collapse when already open on it, switch tab
  otherwise. The control channel never toggles: `casper diff open` and
  `casper browser open` always expand onto their tab, and their `close` forms
  collapse the panel only when that tab is the one showing. There is **no
  separate panel toggle** — no `sidebar.right` button and no
  `toggleInspectorCollapsed` on `AppModel`.
- **Title bar** — the workspace toolbar, in order: one item holding the title
  capsule, the info button and the diff badge; a flexible spacer on macOS 26+;
  then the Merge chip (only for a linked workspace with a base branch), the Run
  Script chip (only with named commands in `.casper.json`), the Editor chip
  (only with a detected editor) and the `InspectorTabSelector` (always).

  The three leading pieces share **one** toolbar item because AppKit inserts its
  own spacing between separate items, which left the glyph-only info chip adrift
  from its neighbours; each chip's own interior padding is what separates them
  now. Every item opts out of the macOS 26 shared "Liquid Glass" background so
  it can draw its own capsule instead of merging into the title's.

  All chrome comes from one shell: a fixed-height capsule with an explicit fill
  and a hairline border, plus a hover highlight for the interactive ones. Glass
  was rejected because it renders nearly invisible on a chip embedding a
  borderless `Menu` (see [[glasseffect-nested-menu-invisible]]), and the fill is
  the same neutral step in both palettes — **no accent colour and no state tint
  anywhere**, so a Delete chip is not red (see [[title-bar-chip-chrome]]). The
  interior padding lives **inside** each control's label, never on the shell, so
  the whole pill is clickable rather than just the glyph
  ([[title-capsule-hit-area]]); `Label`s pin `.titleAndIcon` because the toolbar
  environment otherwise resolves them icon-only and drops the title
  ([[toolbar-label-style]]). The title capsule itself is chrome-less: it is not
  a control, so it takes the shared metrics without the pill — and it is pinned
  to one line, because a toolbar group with no line limit **wraps** mid-word
  once the toolbar proposes it less than its ideal width, pushing the title bar
  open instead of shortening ([[toolbar-group-truncation]]). It degrades widest
  first, dropping the Space name whole so the branch survives.

  The **diff badge** renders only for a non-zero summary, and clicking it
  toggles the panel on the Diff tab — the same mutator as the segments, not an
  expand-only shortcut. Run Script and Editor are split buttons whose menu
  **only selects**; just the primary action runs or launches. The
  `InspectorTabSelector` is one capsule enclosing two glyph-only segments with a
  single sliding indicator: rendering it as a segmented control rather than two
  identical pills is what makes it legible that at most one tab can be on, and
  the third state — collapsed, no indicator at all — is the reason the indicator
  is a single shared shape.

  The **Merge chip becomes a Delete chip while Option is held**. Both answer the
  same question at the same moment — this workspace is done — so they share one
  chip rather than exiling the "not worth merging" case to the sidebar menu, and
  both open a confirmation, so an accidental Option press costs nothing. Merge
  routes to the same merge-and-close confirmation as the menu item; there is no
  merge-only flow, and the dialog is what spells out the "and close". The swap
  is **one `Button` whose label, action and tooltip change**, not two views
  behind a condition, so the chip is never torn down and rebuilt as a modifier
  is tapped. `AppModel.optionKeyHeld` is read inside the chip's
  own body, so only that chip re-renders on a modifier change; it is fed by a
  **local** `NSEvent` monitor (no Accessibility permission), set only for
  Option held *alone* — other combos belong to other shortcuts — and forced
  false on resign-active so Cmd-Tabbing away mid-hold cannot leave the chip
  stuck on Delete.
- **Workspace info panel** — `casper info set` publishes Markdown into a
  popover anchored on a toolbar chip (see `cli-agents.md` for the verbs). The
  chip is **always mounted** and animates by property — opacity, scale, slot
  width — never by a `transition`, because SwiftUI transitions do not play
  inside an AppKit-hosted toolbar item. Zero width and zero opacity are not zero
  interaction, so hit-testing is disabled with them. Its collapsed slot is a few
  points wide rather than zero: `.frame(width:)` fixes the size it reports and
  the trailing padding lives inside it, so at zero the branch title would sit
  cramped against the diff badge. Unread state is carried by the symbol fill
  plus a repeating pulse — **no hue**, so it never competes with the diff
  counter's tints, alongside the usual full-strength/dimmed emphasis swap.

  Hovering reveals the panel after a short dwell and dismissal waits out a grace
  period, so the pointer can travel from the chip into the popover to scroll,
  select or click. Leaving the popover **re-arms the same grace period**: it is
  a bounded travel allowance, not a one-way switch that disables hover dismissal
  for the rest of the popover's life. A click reveals immediately, and revealing
  marks the message seen, which stops the pulse.

  The Markdown is rendered through a **native TextKit path**, not a package:
  Foundation parses it (GFM on, partial parse on failure) and the result is
  styled into an `NSAttributedString` — headings, lists, code blocks, block
  quotes, tables, task lists, thematic breaks — hosted in a read-only,
  selectable `NSTextView`. Images render as **alt text only**, so the panel
  issues no network requests. All chrome derives from the caller's text colour
  rather than hardcoded values, so it follows the theme. The panel carries **no
  Copy button**: one `NSTextView` answers ⌘A/⌘C over the whole message
  natively, so a button would duplicate a shortcut that already works — this is
  a deliberate departure from the approved design, alongside the tighter hover
  dwell and the absence of capsule chrome. Links open in the workspace's **own
  browser** by default (a published endpoint is almost always local) and in the
  system browser when ⌘ is held; ⌘ is the one modifier `NSTextView` does not
  already spend on a click. That routing is a pure decision so tests can pin it
  without a browser launching. See [[nstextview-link-cursor-and-selection]],
  [[markdown-one-sided-spacing]], [[nstextblock-border-unreliable]].

  Sizing takes the **maximum** of two independent measurements — a throwaway
  TextKit 2 measurement made before any view exists, and the height the hosted
  view reports after laying out — because AppKit silently migrates the view to
  TextKit 1 once the message contains a table, and the two engines lay the same
  string out differently ([[textkit1-fallback-on-nstexttable]]). Both are lower
  bounds and the failure modes are asymmetric: too tall costs a little invisible
  scroll slack, too short silently eats lines. The result is applied as a **cap,
  not a pinned height**, so the panel yields to a host with less room instead of
  hanging its tail somewhere unreachable ([[scrollview-viewport-vs-document]],
  [[nstextview-caller-sized-frame]]).
- **Open in Editor** — a split button launching the worktree in VS Code,
  IntelliJ IDEA or Xcode. Detection resolves **app bundles only** and runs
  **once** per launch: requiring the CLI shim would report an editor as missing
  merely because it does not install one automatically, and nothing re-detects
  mid-session, so an editor installed while Casper runs appears after a
  relaunch. Launching still **prefers the CLI shim** when it resolves on the
  user's interactive login shell `PATH` ([[shell-path-resolution]]) — it is
  faster and reuses an open window better — and falls back to opening the
  resolved bundle otherwise.

  The current editor resolves as: an explicit pick → the workspace's remembered
  `lastUsedEditor`, **but only if it is still detected** → the first detected
  editor. That resolution is pure, so it is testable without touching a process.
  Choosing from the menu only records the preference; only the primary action
  launches, and a successful launch records what it launched. A remembered
  editor that is no longer installed is never returned, and is **deliberately
  not cleared** — reinstalling it honours the original preference again. A new
  **linked** workspace, and an adopted worktree, inherit the selection from the
  workspace that was active when creation was requested, read before the
  selection moves; a brand-new Space's primary workspace starts with none.
- **Closing a workspace** — "Merge and Close" and "Delete" are async
  main-actor operations behind a window-modal progress sheet, and every
  blocking libgit2 or filesystem call inside them hops to a **detached task**,
  so a slow `teardown` hook, a large worktree or a slow base resync no longer
  looks like a frozen app. Offloading is safe because `WorktreeManager`'s entry
  points are not actor-isolated, each opens its own repository so no libgit2
  object crosses a thread, and libgit2's error state is thread-local. **All
  model mutation stays on the main actor** — the hop runs the git work and
  nothing else.

  Close is five steps, four without a `teardown` hook; delete is two, one
  without. The hook's presence is resolved **once** up front, and that same
  resolution is what runs — the config file is never read twice. A skipped step
  is skipped by not reporting it, so no call site does index arithmetic. Only
  the hook step carries a deadline, and it travels as an absolute date so no
  timer state lives in the model.

  The sheet has **no buttons and cannot be dismissed**: neither the merge nor
  the worktree removal can be stopped midway without leaving the repository
  half-done. The one long wait shows a countdown to its timeout instead. Its
  reporter withholds the value for a moment so a fast close never flashes a
  panel, and owns the shared published value **by identity** — it writes and
  clears only while that value carries its own workspace id, so overlapping runs
  can neither steal nor, the case that actually mattered, dismiss each other's
  sheet.

  `AppModel.closingWorkspaces` claims a workspace **synchronously, before the
  first `await`**, and releases it in a `defer` covering the whole operation
  rather than just the hook wait: the async conversion made an entry check
  meaningless on its own, and both a menu action (a window-modal sheet does not
  disable the menu bar) and `casper workspace delete` can arrive mid-flight —
  which would strand a continuation and run two libgit2 writers at once. The
  control-channel path is deliberately silent: it reports back as JSON and gets
  no sheet.

  A failing hook **never blocks the destroy**. A non-zero exit or a timeout
  posts an active user notification — the only place it surfaces outside the
  log; a spawn failure is Casper's own fault rather than the user's script, so
  it stays log-only. Operation failures go to an alert that is silent when the
  workspace is already gone, and that reaches the screen through
  [[main-run-loop-hop]] so a failure during another modal panel is not held back
  for that panel's whole lifetime.
- **Wiring** — starts the release control server (`casper` CLI → `AppModel`),
  injects the bundle exec dir + per-surface env into each terminal, and runs the
  `#if DEBUG` debug bridge (all detailed in `cli-agents.md`).

## Sub-projects

- **UI-1 — ✅ built.** App shell (SwiftUI `App` scene +
  `NSApplicationDelegateAdaptor`; Casper owns its **entire** menu bar through
  SwiftUI `.commands` — the only `NSMenu` built in AppKit is the pane context
  menu, see `terminal.md` § Design → "Main menu"),
  `@MainActor @Observable AppModel` as the single state owner/bridge,
  `NavigationSplitView` with empty state, "Add folder…" (adopt any folder — Git
  or not, multiple allowed), one live terminal per workspace, and all startup
  wiring (the release control server, per-surface env, session persistence,
  `#if DEBUG` debug bridge). No Git worktree creation. Renders only the
  single-terminal layout.
- **UI-2 — ✅ built.** The `Space` level (`Session → Space → Workspace`;
  `repoPath` moved up to `Space.folderPath`; `Workspace` gained
  `kind: primary|linked` and `baseBranch`). Opening a folder builds a Space (Git
  or not — non-Git folders are degenerate Spaces with one primary workspace and
  no worktree creation), with **one Space per Git repository** — identity being
  the common `.git` directory every working tree of a repository shares. A
  folder that is a **linked worktree of a repository already open as a Space**
  is adopted into that Space as a linked workspace instead of becoming a Space
  of its own (nothing is created on disk, so no `setup` hook runs); a folder
  that is a **linked worktree of a repository not open** pulls that repository
  in rather than standing alone — the Space roots at the repository's **main
  working tree**, built exactly as opening that folder would build it (its name
  taken from the `origin` remote, its primary workspace sitting on the
  repository's checked-out branch, typically `main`), and the folder the user
  picked joins it as a **linked** workspace named after its branch, with the
  primary's branch as its `baseBranch`; that linked workspace is the one
  selected, being the folder actually chosen, and again nothing is created on
  disk and no `setup` hook runs. That main working tree is resolved with
  libgit2: opening the repository's common `.git` directory, shared by every
  working tree, yields the main repository, whose workdir is the folder to root
  at. A worktree of a **bare** repository is refused: rooting at a main working
  tree is the rule, a bare repository has none and never will, so that layout is
  one Casper does not support and the alert says exactly that. So is a worktree
  whose main working tree does not come back as a folder of the *same*
  repository — the repository directory gone from disk, or a
  `--separate-git-dir` layout, which records no `core.worktree` and so has
  libgit2 answer the git directory's parent, an unrelated existing folder a
  same-repository guard rejects. Either way the picked folder is **refused
  outright**: nothing is added and an alert says so, there being deliberately no
  silent fallback to a Space rooted at the worktree, precisely the shape this
  rule exists to avoid. Conversely, opening a **repository whose worktrees are
  already open as Spaces** reunifies them into the Space it creates, moving
  those workspaces whole (ids, ports, layouts and live terminals unchanged) with
  each ex-primary becoming a linked workspace named after its branch. Re-adding
  a folder Casper already tracks only selects it; a per-Space "+" creates a
  **linked** workspace as a new branch + `git worktree` at a visible sibling of
  the repo folder, `<parent>/<repo>-<branch>` (outside the repo, so naturally
  untracked — no in-repo `.casper/worktrees/` and no `.git/info/exclude` entry;
  a `-2`/`-3`… suffix is used if the sibling name is taken). The sidebar is
  grouped by Space in collapsible sections; removal is non-destructive (drop a
  linked workspace, or a whole Space, leaving worktrees/branches on disk); a
  degenerate Space is promoted to Git when its folder gains a `.git` (detected
  live by the filesystem watcher, and once per Space at launch), and demoted
  back if the `.git` is removed. The per-workspace `+/−` diff summary is
  **dropped** (decision 2026-07-06) — see the "Next action" note below.
- **UI-3 — ✅ built, then reshaped into panes.** Recursive `LayoutNode`
  composition. Splits render through the custom `SplitContainerView`, which
  lays panes out by fraction along the axis. Native `HSplitView`/`VSplitView`
  were dropped because their divider was near-black and stood out; a separator
  is now a drawn 1 pt hairline with a wider **transparent** grab strip over it,
  carrying the resize cursor and the drag without reserving visible width. Both
  come from `SeparatorMetrics`, the one contract the inter-pane, inspector and
  inspector-edge separators all read, so they cannot drift apart. The grab strip
  is a concrete `NSView`: a SwiftUI `.pointerStyle` loses the cursor to the
  terminal surface's own `cursorUpdate` ([[terminal-overlay-cursor]]). Panes are
  placed with explicit non-overlapping frames, because libghostty's
  `CAMetalLayer`-backed terminals ignore SwiftUI `.opacity` and would occlude
  one another. Right-clicking a pane opens the split/copy/paste/close menu.

  Surface views live in a persistent cache keyed by `Surface.id`, so a PTY
  survives split, collapse and reorder (identity is anchored solely on
  `Surface.id`); only the layout may bring a view into existence, so a `Surface`
  value the tree no longer holds cannot refill the cache — see
  [[surface-view-layout-membership]]. Pane fractions seed from the layout's
  persisted `ratios` and are written back through `AppModel.setSplitRatios` →
  `LayoutTree.updateRatios` (debounced save) on drag-end and on
  double-click-to-equalize, so a resize survives relaunch. libghostty
  `newTab`/`newSplit`/`closeTab` route through a `LayoutActionHandler` installed
  on the runtime to the **focused** workspace (focus tracked via the surface's
  first-responder callback). Closing the last surface re-seeds the workspace
  with a fresh terminal instead of closing it, so panes alone never remove a
  workspace or a Space. The pure tree operations live in CasperCore and are
  heavily tested (see § Design → "Layout composition", which also owns the
  action mapping).

  > **Superseded:** this sub-project shipped with **tab groups** — a
  > Ghostty-style bar of rounded pill tabs with a hover-revealed `×` and a
  > trailing `+` menu, a tab group rendering only its active surface. Tabs were
  > removed entirely for the tmux-style model above: `LayoutNode` is
  > `split | leaf`, `TabBarView` is deleted, and `tabGroup` survives only as a
  > legacy decoding key that migrates an old session into an even horizontal
  > split. Two follow-ups the tab bar carried
  > went with it — deriving tab shades from the live terminal background, and
  > per-tab `⌘N` switching. `⌘N` came back at a different scope: ⌘1–⌘9 select
  > **workspaces** (`AppModel.workspaceShortcutNumbers` numbers them down the
  > sidebar, `WorkspaceShortcutKeyMonitor` maps them by physical key code so
  > AZERTY works), and holding ⌘ for ≥250 ms reveals the hints in the rows.
- **UI-4 — ✅ built.** A `WKWebView` browser surface (address bar with bare-host
  normalization, back/forward/reload). It originally rendered `.browser` layout
  leaves created from the tab-bar "+" menu; the tmux-pane redesign removed that
  entry point, and the browser now lives in the inspector panel only. The web
  view lives in the persistent surface-view cache keyed by `Surface.id`
  (generalized from UI-3 to hold any `NSView`), so it survives layout
  restructuring like terminals.

  Its URL is persisted from **both** ends. The address bar writes it, and so
  does the page: `BrowserCoordinator` reports every committed navigation through
  `onCommitURL`, wired by `AppModel.browserCoordinator(for:)` to
  `AppModel.setBrowserURL`, which no-ops when the stored URL already matches so
  a page load cannot thrash `session.json`. Covered by
  `Tests/CasperUITests/BrowserURLSyncTests.swift`. Same-document navigations
  need KVO rather than the navigation delegate — see
  [[webkit-page-driven-navigation]].
- **UI-5 — ✅ built.** A read-only diff surface over CasperGit's
  `diffWorkdirToHead()`: per-file sections (path + status, binary files noted),
  hunk headers, and monospaced line rows colored by kind (green addition / red
  deletion / neutral context) with old/new line-number gutters and a
  `+`/`-`/space prefix cue. Computed on open and **live-refreshed**: a native
  FSEvents watcher on the selected workspace's folder (debounced ~200 ms, `.git`
  + Git-ignored top-level dirs excluded) bumps an observable revision that both
  the diff surface and the title-bar `+/−` badge react to. Originally rendered
  as a `.diff` layout leaf (created via the tab-bar "+" menu); that surface kind
  was later **removed** — the diff view now lives **only** in the right
  inspector panel (`Workspace.inspector`). The rendering above is unchanged,
  just hosted by the inspector instead of a layout leaf.

  > **Superseded:** the per-line rendering described above (a `LazyVStack` of
  > per-file sections, one SwiftUI row per diff line, pinned `Section` headers)
  > is replaced by a single TextKit 2 text document, which also adds text
  > selection and copy. The diff computation, the FSEvents live refresh and the
  > reading experience are unchanged. The as-built pipeline is § Design → "Diff
  > viewer" above.

## Next action

**All five CasperUI sub-projects (UI-1..UI-5) are built** and have passed the
live GUI verification pass on a real desktop (panes, browser navigation, diff
surface); two areas still want a human eye, listed in `../status.md`. The
outstanding **feature** is **Space rename**; the other open CasperUI items are
in `../status.md` § Remaining work. (The Space `+/−` per-workspace diff summary
was **dropped** — decision 2026-07-06; the title-bar working-tree-vs-HEAD
summary covers the need.)
