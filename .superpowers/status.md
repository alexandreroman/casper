# Casper — Implementation Status

The single, authoritative record of implementation progress. The design source of
truth is [`architecture.md`](architecture.md) plus the per-theme docs in
`themes/`; the documentation map is [`INDEX.md`](INDEX.md); active plans are in `plans/`.

Status legend: ✅ built · ◐ partial · ❌ not started.

## Roadmap at a glance

The build proceeds in five module plans. **All five are implemented.** CasperUI
(Plan 5, the real SwiftUI app) is complete across its five sub-projects: **UI-1**
(app shell + startup wiring), **UI-2** (Space model + Space-grouped sidebar +
linked Git worktrees), **UI-3** (recursive splits/tabs layout), **UI-4** (WKWebView
browser surface), and **UI-5** (read-only diff viewer). The live GUI verification
pass on a real desktop is complete. The v1 agent target is Claude Code only.

| Plan | Module                   | Status                                                                                       |
| ---- | ------------------------ | -------------------------------------------------------------------------------------------- |
| 1    | CasperCore               | ✅                                                                                            |
| 2    | CasperGit (+ Clibgit2)   | ✅ worktrees/status/`remoteURL`/`git_diff` built                                              |
| 3    | CasperCLI + CasperAgents | ✅                                                                                            |
| 4    | CasperGhostty            | ✅ one terminal + splits/tabs composed by UI-3                                                |
| 5    | CasperUI + app           | ✅ UI-1..UI-5 built (sidebar + worktrees + splits/tabs + browser + diff); live GUI check done |

Two developer-tooling features are built on top (both `#if DEBUG`): the
debug/observability channel and debug surface addressing. The Space (project)
model shipped with UI-2; only **Space rename** remains open for it (the
per-workspace `+/−` diff summary is **dropped** — decision 2026-07-06).

> **Latest work — the tabbed surface model (UI-3) is replaced by a tmux-style
> pane layout** (no tabs, one surface per pane), with close-on-process-exit and a
> shared-NSView collapse fix. See
> [Surface layout — tmux-style panes](#surface-layout--tmux-style-panes-supersedes-ui-3-tabs--) below. UI-3 sections in this file and in `themes/app-ui.md`
> describe the superseded tab model.

## Modules

### CasperCore — ✅
Models (`AgentState`, `Todo`, `LayoutTree`, session), `WorktreeManager`
(create/list/remove/deleteBranch/isClean with `WorktreeError` mapping),
`PortAllocator`, `SessionStore`, and the control-channel protocol + socket
(`ControlProtocol`/`ControlSocket`) plus CLI-targeting/progress helpers.

### CasperGit + Clibgit2 — ✅ (core)
`Repository` (open/discover/init, branch queries, worktree
add/list/lookup/validate/prune, status/isClean, `remoteURL`, `diffWorkdirToHead`),
`Worktree`, `GitError`.
- **`git_diff` is built** — `diffWorkdirToHead()` returns a structured
  `GitDiff` (files → hunks → lines, statuses, binary flag; working tree + index
  vs HEAD, unborn HEAD as additions), unblocking the diff viewer (design §11).
  (Branch-divergence diffs were designed for the Space `+/−` summary, now
  dropped — not built.)
- Standing limitations: `remove` prunes the worktree but not its branch, so
  recreating a same-named workspace surfaces an opaque `.gitFailure` (fix by
  mapping it to a clear reason or deleting the branch on remove); libgit2 is
  unpinned in brew/CI; `WorktreeManager` opens the exact repo root
  (`Repository.open`) rather than `discover`.

### CasperAgents + CasperCLI — ✅
`ClaudeCodeAdapter.surfaceEnvironment` (per-surface env injection); the `casper`
executable with the GUI/CLI fork and the domain CLI
(`status`/`progress`/`notify`/`terminal`/`browser`/`diff`/`workspace`) that emits
JSON over `$CASPER_CONTROL_SOCKET` (errors exit non-zero). There is **no hook
mechanism** — a workspace's agent state is set only by the explicit CLI verbs. See
the `domain-cli-control-channel` memory note for the current surface.
- The bundle executable directory is injected onto each surface's `PATH` (via
  `surfaceEnvironment(casperDirectory:basePath:)`) so `casper` resolves inside
  Casper terminals.
- **Browser automation — ✅.** `casper browser` gains six verbs
  (`screenshot`/`eval`/`content`/`click`/`type`/`key`) that drive the
  workspace's inspector `WKWebView` over the control channel: JS-synthesized
  input, `takeSnapshot` screenshots, DOM extraction, and JS eval. Pure JS
  generation lives in `BrowserAutomation`; verified end-to-end against a live
  page. See the `browser-automation-cli` memory note.
- **Browser debugging — ✅.** Three more verbs (`console`/`wait`/`reload`) turn
  the panel into a debug surface: page `console.*` + uncaught-error capture (a
  500-entry ring buffer fed by an injected `WKUserScript`), deterministic waits
  (selector present/visible/gone or a `--js` predicate), and reload. Verified
  end-to-end against a live page. See the `browser-automation-cli` memory note.
- **Background browser — ✅.** `browser load <url>` mirrors `open` but does not
  open/select the inspector (a background navigation, for driving a hidden
  browser in parallel), and `screenshot --width/--height` set the off-screen
  render viewport. Sized captures (`--width/--height`, plus an optional `--url`
  to grab an arbitrary URL headlessly) render in a dedicated off-screen
  `WKWebView` (`BrowserCapture`), so responsive layouts (mobile/wide) capture
  faithfully **regardless of the panel state** — verified with the panel open.
  All browser verbs target a workspace by id independent of selection and work
  off-screen — see the `browser-automation-cli` note's off-screen caveats.

### CasperGhostty — ✅ (one terminal end-to-end)
`GhosttyRuntime`, `GhosttyAction`, `GhosttySurface` (+
`GhosttySurfaceConfiguration`), `GhosttySurfaceView`, `GhosttyInput`,
`GhosttyDefaultConfig`, `GhosttyActionDispatcher`, and `PersistentNSViewHost`
(the SwiftUI bridge that re-parents an existing `NSView` instead of recreating
it). Rendering is display-link driven, so `GHOSTTY_ACTION_RENDER` needs no
explicit `draw()` wiring.
- **Keyboard & clipboard — ✅.** Control/Option/⌘ combos all work (Ctrl-C/D,
  ⌘C/⌘V/⌘A via NSPasteboard, ⌘±/0 font size, ⌘Q, ⌘W); macOS menu bar
  (App/Edit/View/Window); `macos-option-as-alt` wired (inert in the pinned
  binary). ⌘-key/menu paths confirmed by structure + live keypress (the debug
  channel bypasses `performKeyEquivalent`).
- **Mouse — cmd+click opens URLs — ✅.** libghostty forwards the ⌘ modifier and
  emits `GHOSTTY_ACTION_OPEN_URL` when a terminal link is cmd+clicked; the action
  decodes into `GhosttyAction.openURL` and opens via `NSWorkspace`, matching
  upstream Ghostty (any parsable URL, no scheme restriction).
- **Layout composition — ✅.** Decoded actions are routed through
  `GhosttyActionDispatcher` into CasperUI's `LayoutActionHandler` (installed on
  `GhosttyRuntime.actionHandler` by `AppDelegate`), which composes them into the
  recursive tmux-style `LayoutNode` tree — see "Surface layout" below.
- **`flagsChanged` press/release and scroll precision/momentum — ✅.** Modifier
  transitions report press-while-held / release-when-let-go from the physical
  key code, and `scrollWheel` packs the precision bit and momentum phase into
  `ghostty_input_scroll_mods_t`.
- Remaining for CasperUI: clipboard paste-confirmation UI (v1 auto-confirms).

### CasperUI — ✅ UI-1..UI-5 built (live GUI check done)
The module exists. **UI-1** is done: a SwiftUI `App` scene
(`CasperApp`/`AppDelegate`/`CasperUI.runApp`) replaces the Ghostty demo as the
GUI entry point; a `@MainActor @Observable AppModel` owns the session and bridges
the core types to SwiftUI; a `NavigationSplitView` shows an empty state, an
"Add folder…" flow and one live terminal per workspace; and all startup wiring is
landed (per-surface env, the release control channel, session persistence,
`#if DEBUG` debug bridge). Release gating verified (no
debug symbols in `make release`). UI-1 is verified live on a real desktop session.

**UI-2** is done: the `Space` level (`Session → Space → Workspace`; `repoPath`
moved up to `Space.folderPath`; `Workspace` gained `kind: primary|linked` and
`baseBranch`). Opening a folder builds a Space — Git or not (non-Git folders are
degenerate Spaces: one primary, no worktree creation), with **one Space per Git
repository** enforced both ways: a folder that is a linked worktree of a
repository already open as a Space is adopted into that Space as a linked
workspace (same branch, the Space's primary branch as its base, nothing created
on disk and no `setup` hook, since the worktree already exists); and opening a
repository whose worktrees are already open as Spaces of their own **reunifies**
them into the Space it creates — those workspaces move whole (same ids, ports,
layouts and live terminals), each ex-primary becoming a linked workspace named
after its branch, and a workspace that already recorded a base branch keeps it.
Repository identity is libgit2's common `.git` directory, shared by every
working tree of a repository. Re-adding a folder Casper already tracks just
selects it. A Space is promoted to Git when a `.git` appears — detected live by
the workspace filesystem watcher (and once per Space at launch), and demoted
back if the `.git` is removed. A per-Space "+"
creates a **linked** workspace as a new branch + `git worktree` at a visible
sibling of the repo folder, `<parent>/<repo>-<branch>` (outside the repo, so
naturally untracked — the old in-repo `.casper/worktrees/` layout and its
`.git/info/exclude` entry are gone; a `-2`/`-3`… suffix is used if the sibling
name is taken). The sidebar is grouped by Space in
collapsible sections; removal is non-destructive (drop a linked workspace or a
whole Space, leaving worktrees/branches on disk). Persistence is a clean break
(the `SessionStore` self-heal discards incompatible legacy `session.json`). The
`+/−` diff summary is deferred to UI-5.

**UI-3** is done: a workspace renders its `LayoutNode` tree recursively — splits
as native `HSplitView`/`VSplitView`; a tab group renders only its active surface
(Ghostty-style tab bar: rounded "pill" tabs sharing the width equally, centered
titles, the active tab a filled bordered pill and inactive tabs blended into a
fixed dark neutral chrome — no accent color; the whole pill is clickable; a
trailing circular `+` menu; each tab has a leading hover-revealed `×` that closes
that surface by `Surface.id`, preserving the active tab when a background tab is
closed; tying the shades to the live terminal background and `⌘N` switch
shortcuts are deferred), with
inactive surfaces kept alive in a persistent cache (PTYs running) and re-attached
on re-selection (rendering only the active surface avoids overlapping
`CAMetalLayer` terminals that ignore SwiftUI opacity). Pure `LayoutTree` operations
(`insertTab`/`split`/`closeSurface`) live in CasperCore; libghostty
`newTab`/`newSplit`/`closeTab` route through a `LayoutActionHandler` (installed on
`GhosttyRuntime.actionHandler`) to the focused workspace, focus tracked via the
surface first-responder callback added in CasperGhostty. Closing the last surface
closes the workspace non-destructively. Surface views live in a persistent cache
keyed by `Surface.id` so PTYs/web state survive restructuring.

**UI-4** is done: `.browser` leaves render a `WKWebView` surface (address bar with
bare-host normalization, back/forward/reload), created via the tab-bar "+" menu
(New terminal / New browser). The web view is cached by `Surface.id` (the cache
generalized to any `NSView`) and its URL persists via the address bar. Only
`.diff` leaves remain a placeholder (UI-5).

**UI-5** is done: `.diff` leaves render a read-only diff surface over
`diffWorkdirToHead()` — per-file sections (path + status, binary noted), hunk
headers, and monospaced line rows colored by kind (addition/deletion/context)
with old/new line-number gutters; computed on open and **live-refreshed** by a
native FSEvents watcher on the selected workspace's folder (debounced ~200 ms;
`.git` + Git-ignored top-level dirs excluded) that bumps an observable revision
driving both the diff surface and the title-bar `+/−` badge.

> **Superseded:** the `.diff` layout-leaf surface kind (and its "New diff"
> tab-bar menu item) was later **removed** — the diff view now lives **only** in
> the right inspector panel (`Workspace.inspector`, see below). The `.browser`
> layout-leaf path still exists; `.diff` does not. The diff rendering described
> above is unchanged, just hosted by the inspector instead of a layout leaf.
>
> **Superseded:** the per-line SwiftUI rendering described above (a `LazyVStack`
> of `DiffFileView` sections, one `DiffLineRow` per diff line, pinned
> `Section` headers) was replaced by a **single TextKit 2 text document**. See
> [Diff renderer](#diff-renderer--one-textkit-2-text-document-supersedes-ui-5-rows--)
> below. The reading experience and the diff computation are unchanged; what
> the reader sees drawn is now AppKit, not SwiftUI.

All five CasperUI sub-projects are built. **Live GUI check: done.** Terminals
render on a restored session and tab switching preserves content — verified via
the `casper debug` channel on a real desktop (this fixed a restore-path bug where
a non-observed `runtime` left terminals black; see the ledger).

Post-milestone tab-bar polish landed (all on `main`, not pushed; see the ledger's
"Tab-bar polish" section for commit hashes): a per-tab hover-revealed `×` close
button (closing any surface by `Surface.id`, preserving the active tab when a
background tab closes — with a regression test), Ghostty-style rounded "pill"
tabs sharing the width with centered titles and a circular `+` menu, full-tab
click (not just the title), and a fix so a clicked tab's terminal takes AppKit
keyboard focus (`focusActiveSurfaceView()` → deferred `makeFirstResponder`).

Still to verify live: the terminal-focus-on-tab-switch fix (click a
tab, then type — the keystroke must reach the terminal), the Ghostty tab
appearance vs the reference screenshot, full-tab click, and — open from before —
splits, browser navigation, and the diff surface. Deferred follow-ups: deriving
tab shades from the live terminal background color (Casper does not yet read
libghostty's `background-color`), and per-tab `⌘N` switch shortcuts.

## Surface layout — tmux-style panes (supersedes UI-3 tabs) — ✅

The tabbed surface model (UI-3) is replaced by a **tmux-style layout**: no tabs,
one surface per pane. Landed on `main` (not pushed) in three commits:

- `656ce2a` Replace tabbed surfaces with a tmux-style pane layout
- `ad9847c` Close a terminal surface when its process exits
- `6b0dbab` Fix blank pane on split collapse from shared NSView host

**Model.** `LayoutNode` is now `split | leaf(Surface)` (no `tabGroup`); each leaf
holds one surface. A hand-written `LayoutNode` `Codable` migrates persisted
`tabGroup` sessions (N surfaces → even horizontal split of N leaves).
`LayoutTree` keeps `split`/`closeSurface`/`mapSurface`/`surfaceIDs`;
`insertTab`/`activate` are removed. `GitDiff` gained `insertions`/`deletions`.

**Rendering.** Leaves render via `SurfaceHostView` (no tab bar; `TabBarView`
deleted). Right-click on a pane opens the pane menu: Split up/down/left/right
(each creates a terminal), Copy/Paste, Close pane. Splits render via a custom
`SplitContainerView` (replacing native `HSplitView`/`VSplitView`) that separates
panes with system `Divider()`s — so every separator in the app (sidebar/content
edge, inspector panel, inter-pane) shares one color; the native split divider was
darker (near-black) and stood out. Panes are laid out by fraction along the axis
with draggable `Divider()` handles (left-right / up-down resize cursor); fractions
live in local `@State` (resize is not persisted, matching v1). Leaves keep
explicit non-overlapping frames so the Metal-backed terminals never occlude.

**Chrome.** The native window toolbar (with the native sidebar toggle) shows the
branch-icon title + worktree path, the `+ins −del` diff summary
(`AppModel.diffService.diffSummary` via `computeDiff`), and side-by-side
new-terminal / new-browser buttons (both split right). "Add Space" stays
sidebar-side. Sidebar rows show a neutral branch icon, a full-width todo
progress bar with the current task, and a notification bubble; Spaces stay
collapsible; the per-Space "+" adds a linked workspace.

**Close-on-exit.** libghostty `close_surface_cb` (Ctrl-D / `exit`) is wired via
`GhosttySurfaceView.onClose` → `AppModel.applyCloseSurface`; closing the last pane
closes the workspace non-destructively. The callback defers to the next runloop
turn (like `wakeup_cb`) to avoid re-entering the runtime mid-tick.

**Bug fixed.** On a split→leaf collapse a stale SwiftUI host stole the survivor's
shared `NSView` into a container about to leave the window, blanking the pane.
`PersistentNSViewHost` now runs a next-runloop, window-guarded reconcile so only
the host whose container stays in the window keeps the view. See the
`persistent-nsview-host-sharing` project-memory note.

**Verified** via the `casper debug` channel + screenshots on a real desktop:
`tabGroup`→`leaf` session migration, continuous split panes with no tab bar,
terminal + browser panes side by side, sidebar progress/notification, the live
diff summary, and close-on-exit collapsing two panes to one (the survivor stays
rendered). `swift test` → 259 passing.

**Follow-ups.** (1) Browser panes: WebKit consumes the right-click, so the Casper
split menu does not yet surface over live web content (the native menu is
suppressed). (2) The toolbar diff summary uses working-tree-vs-HEAD; the Space
branch-vs-merge-base `+/−` summary was **dropped** (decision 2026-07-06), so this
is now the intended behaviour, not a stopgap.

## Right inspector panel — ✅ (live check done)

A collapsible right-side panel on the workspace detail view exposes a **browser**
and the **Git diff** as two tabs, per workspace. The `.diff` layout-leaf surface
kind was **removed** — the diff view now lives **only** in this inspector panel.
The `.browser` layout-leaf path still exists (a browser can still be a tmux
pane); `.diff` does not. The title-bar globe "New browser" button is removed.

**Model.** `Workspace` gained `inspector: InspectorState` (`collapsed`, `tab:
InspectorTab{browser,diff}`, and a dedicated `browser: Surface`). A hand-written
`Workspace.init(from:)` decodes `inspector` with `decodeIfPresent ?? .init()` so
pre-existing `session.json` files load with a default (collapsed, Diff tab,
`about:blank` browser); `encode` stays synthesized. State is per-workspace and
persisted.

**UI.** `WorkspaceDetailView` lays the detail out as an `HStack`: the tmux
`LayoutNodeView` (`maxWidth: .infinity`), a `Divider()` (system separator, matching
the sidebar/content edge), then `InspectorPanel` at a state-driven `width`
(`InspectorState.defaultWidth` = 780, clamped 240–1400). The panel is **always
mounted**; collapsing animates an outer clip container's width to zero rather
than unmounting it, so the icon rail pinned to the trailing edge never
translates — see [[swiftui-inspector-width]]. The `Divider()` doubles as a drag
handle (transparent 10 pt hit area, left-right resize cursor) that resizes the
panel, and lives inside the same clipped container so it reveals with the panel.
Because the left region stays `maxWidth: .infinity`, the width is **unaffected
by adding terminals**. It is a side region, not an `HSplitView` pane (which
would reset the width on re-add). The width is **persisted**:
`InspectorState.width` is `Codable` with its own coding key, and a legacy
`session.json` without it decodes to the default. `InspectorPanel` pins a
vertical, icon-only Diff/Browser tab rail to
its right edge, alongside **full-bleed** content (no insets — a native
`TabView`'s mandatory content inset was rejected), reusing `BrowserSurfaceView`
(on `inspector.browser`) and `DiffSurfaceView` unchanged. The panel is collapsed only
via the title-bar toggle (no in-panel collapse button). The panel browser's
`WKWebView` survives collapse/expand and workspace switches via the existing
surface-view cache (stable `Surface.id`); its address-bar URL write-back reaches
`inspector.browser` through an extended `setBrowserURL` (fall-through on a
`locateSurface` miss). Diff is on-demand (open + refresh).

**Chrome.** The title bar drops the globe "New browser" button and gains a panel
toggle (`sidebar.right`, tinted when expanded); the `+ins −del` diff summary is now
a button that expands the panel on the Diff tab. "New terminal" is unchanged.

**Tests.** `swift test` → 266 passing, incl. `InspectorState` defaults, `Workspace`
round-trip with a non-default inspector, legacy-decode without the `inspector` key,
the three `AppModel` inspector mutators, and the inspector-browser URL write-back.

**Verified.** Live GUI pass (`debug-casper`): panel toggle, tab switch, browser
survival across collapse/expand and workspace switch, and a terminal pane not
blanked when toggling the panel (see `persistent-nsview-host-sharing`).

## Diff renderer — one TextKit 2 text document (supersedes UI-5 rows) — ✅

The diff is drawn as **one TextKit 2 text document** instead of thousands of
SwiftUI views. Landed on `main` in six commits:

- `5b84769` Add DiffDocument, the diff view's pure rendering model
- `a4f5f22` Assemble the diff text storage from a DiffDocument
- `fa08e55` Map TextKit fragments back to diff lines
- `12ea054` Draw diff row tints and the gutter from fragment geometry
- `dd9806a` Host the diff text view with a pinned file header overlay
- `21de38f` Render the diff through the TextKit surface

**Pipeline** (`Sources/CasperUI/`, pure → pixel):

- `DiffDocument.swift` — a `Sendable` value flattening a `GitDiff` into flat
  text plus per-file and per-line spans (`NSRange`s, kinds, gutter numbers,
  truncation flags), built **off the main actor**. One `LineSpan` is exactly one
  TextKit paragraph (embedded paragraph separators are flattened to spaces,
  1:1), and every `FileSpan` owns at least one paragraph (a mode-only change
  gets a `No content changes` note), so no two files share a start offset.
- `DiffTextAssembly.swift` — builds the `NSTextStorage`: one document-wide
  attribute pass plus overrides for the chrome lines and the reserved header
  band. Also the **only** writer of attributes afterwards, and `applyHighlight`
  sets nothing but `.foregroundColor` — a metric-bearing attribute would reflow
  the document under a reader mid-scroll.
- `DiffFragmentGeometry.swift` — the **single** reader of TextKit layout:
  fragment → diff-line mapping, file tops, viewport enumeration. There is no
  TextKit 1 fallback on purpose (a second backend could drift). Enumeration is
  proportional to the visible rect, not to the document.
- `DiffTextView.swift` — `NSTextView` subclass filling each changed row's tint
  across the full view width in `drawBackground(in:)`.
- `DiffGutterRuler.swift` — `NSRulerView` subclass drawing the row tint band,
  the 3 pt accent stripe and the right-aligned line number. Column positions
  match the old `DiffLineRow` exactly (8 pt number-to-code gap, stripe width).
  It clips to its own `bounds` in `draw(_:)`, around `super` — see **Gutter
  clipping** below.
- `DiffStickyHeader.swift` — an overlay reproducing `pinnedViews:
  [.sectionHeaders]`, including the push behaviour. It only **reads** geometry
  and feeds nothing back into text layout.
- `DiffTextSurface.swift` — `NSViewRepresentable` owning the scroll view, the
  explicit TextKit 2 chain, the ruler and the overlay, with a narrow imperative
  API (`apply(document:restoring:)`, `applyHighlight`, `scroll(toFileID:)`,
  `currentAnchor()`).
- `DiffSurfaceView.swift` — SwiftUI, orchestration only: refresh, dedup,
  progressive highlighting, scroll target, empty states.

**Gutter clipping** (`1dc0b09`). A custom `NSRulerView` is handed dirty rects
that reach far outside its column — one draw pass arrives with the rect *and*
the context's clip set to the whole coordinate plane, another with the scroll
view's entire content area (500 pt wide beside a 42 pt gutter, starting a header
band above its top edge) — and AppKit clips none of it. Three paints escaped:
the background fill covered the code the clip view had already drawn (the diff
rendered as bare line numbers over an empty panel); rows above the viewport had
their chrome drawn over the inspector's Diff | Browser selector; and
`NSRulerView`'s own trailing-edge hairline ran the full height of the infinite
clip. The ruler now clips to `bounds` in `draw(_:)` around `super`, which is the
only place that also covers the chrome no method of the class draws. Recorded in
`.claude/project-memory/references/nsrulerview-unclipped-drawing.md`.

**Gained.** Text is **selectable and copyable**, character-level, and a copy
comes out as clean code: line numbers live in the ruler (not the text) and the
header band is `paragraphSpacingBefore` (not characters), so neither ends up on
the pasteboard. Scroll-to-file (`casper diff open <file>`) resolves through
`ensureLayout(throughFileAt:)` instead of deferring a run-loop turn.

**Removed.** `DiffFileView`, `DiffLineRow`, `DiffFileHeaderBar`,
`DiffFileMetrics`, the `FileHighlight` identity-equality trick, the
animation-disabling helper, and `DiffLineStyle.maxWrappedLinesPerRow` (there are
no rows). No `LazyVStack`, pinned `Section`, `.scrollPosition` binding or
`.scrollTargetLayout()` remains anywhere in the diff view.

**Unchanged.** Diff computation (`DiffService.computeDiff` and its SIGBUS
guard), the two FSEvents watchers and `diffRevision`, the byte-identical-diff
dedup, the `DiffHighlighter` pipeline with its shared `Highlight()` instance and
`maxHighlightBytes` cap, highlight carry-over for files whose hunks did not
change, the diff-shape logging, and the three `DiffEmptyState` views.

**Caps.** `DiffLineStyle.maxDisplayLineLength` (2000 chars) kept, with the
`… (line truncated)` marker; `DiffDocument.maxLinesPerFile` (3000) kept; a new
document-wide `DiffDocument.maxTotalLines` (20 000) added — display cost no
longer scales with document length, but building the value and its attribute
runs still does. `maxWrappedLinesPerRow` (40) is gone.

**Data flow.** The document reaches the surface as a **representable property**
keyed by a monotonic revision, not through the controller: routing it through
the controller made the first paint depend on SwiftUI realizing the coordinator
before `.onAppear`. The controller carries only events (scroll target, a file's
highlight finishing). Nothing writes SwiftUI state during layout.

**The `+`/`-` cue lives in the gutter, not in the text.** `DiffGutterRuler` draws
it in a column of its own between the number and the code, in the code face and
the row's accent, once per line rather than once per wrapped display row.
`DiffDocument` emits the source text alone, so `contentRange == range` for every
line but a truncated one. Three things fall away together: a wrapped line's
display rows share one leading edge (prefixed to the text, the cue indented only
the first of them — which is what surfaced this), a selection can no longer
highlight a rendering artefact, and a copy needs no stripping, so `NSTextView`'s
own selection and copy behaviour is left completely alone (shift-click and
shift-arrow extension included). The cue column's width is the code font's `+`
advance **rounded up**: every other term of `ruleThickness` is a whole number of
points, and a fractional total leaves the trailing pixel of the column
half-covered by the row tint — a seam down the gutter's edge, which a pixel probe
caught as stray ink. A truncated line's `… (line truncated)` marker is the one
piece of commentary kept inside the text: it is the only sign that a copy of that
line is a prefix of the real one.

**Highlight repaint order** (`be1445f`). The freeze the **Still to verify** note
below was waiting on did happen, on an actively-edited worktree with the panel
open — and it was not the rewrite's feedback path. `render(_:)` repainted the
carried highlights by iterating `DiffRendering.highlights`, a dictionary, so
files were coloured in hash order rather than the document's. `NSTextStorage`
keeps its attributes in a run-length array and `applyHighlight` writes one
`.foregroundColor` run per syntax run, so painting a file that sits mid-document
memmoves every run belonging to the files below it; ascending order only ever
appends. Measured on a synthetic diff, a 64-file repaint took **0.21 s in
document order against 51.77 s in hash order**, document order holding flat at
0.23 µs per run while hash order quadrupled per doubling of the file count.

`maxTotalLines` bounds one repaint well under the minutes observed, so the
freeze was these bursts *piling up*: `carriedHighlights` carries nearly every
file across a refresh and `render(_:)` repaints all of them, so refreshes
arrived faster than the bursts drained and the main thread never returned to
idle. Painting now walks `DiffDocument.files` and looks each highlight up
(`DiffRendering.highlightsInDocumentOrder`) — monotonic by construction,
O(files), no sort. The order is unobservable in the finished storage
(`applyHighlight` is idempotent and its output order-independent), so that
accessor exists as the pure seam the regression test asserts ascending indices
on. Recorded in
`.claude/project-memory/references/nstextstorage-attribute-run-order.md`.

Two things are deliberately still open: the repaint is one synchronous
main-thread burst, and it repaints every carried file rather than only those
whose text moved.

**Header bars and settled layout** (`427380f`). `DiffStickyHeader.bars` is a
cache, so what invalidates it is part of its contract. Two things did — a
document swap or a viewport resize, and the clip view's bounds changing — and
TextKit finishing its layout was not among them. A swap invalidates the whole
layout while `resolveBarsOverTheViewport()` warms only the viewport, so the
positions the bars resolve from rest on *estimated* heights for everything the
real layout has not reached; the text view's next layout pass replaces those
estimates and moves every fragment below. The row tints and the gutter read
`DiffFragmentGeometry` at draw time and follow the text there, which is why the
bars alone were left behind — stranded inside a file's code with their own bands
blank, healing on the reader's next scroll.

The text view therefore reports its layout passes (`DiffTextView.didLayout`,
after `super.layout()`, where TextKit 2 lays the viewport out) and the
coordinator re-resolves the bars from them — through `updateStickyHeader()`, not
`resolveBarsOverTheViewport()`, which forces layout and so has no business
running inside a layout pass. The re-resolutions are **coalesced**: a refresh
invalidates the layout once per storage swap and once per highlight painted into
it, only the last pass of the burst carries settled geometry, and resolving
costs an O(scroll offset) `fileIndex(atY:)` probe — 1.17 ms deep into a
20 000-line diff. A burst queues exactly one re-resolution via
`CFRunLoopPerformBlock`, whose modes include the nested loops a
`DispatchQueue.main.async` block would sit out
(see `main-queue-starved-by-modal-loops`). The bounds-change path stays
synchronous, so the bar still cannot lag a frame behind the text it labels while
scrolling. Recorded in
`.claude/project-memory/references/textkit2-layout-geometry.md`.

That guard's first CI run failed, on the runner rather than in the app.
TextKit's cold-layout estimates are **macOS-version-specific** — the same
document measures 87 910 pt estimated on macOS 15 against 77 243 pt on
macOS 26 — so a container `y` maps to content thousands of points apart
depending on the OS, and a fixture that placed one file boundary inside a
600 pt window by arithmetic held only on the machine it was measured on. The
runner drew lines 541–548 where development draws 598–605, leaving that
boundary 4 800 pt below the viewport; the bars there were *right* (one pinned
bar, no bands in view), and only the fixture's own preconditions failed. So the
fixture is 300 short files rather than three tall ones: with every file shorter
than the viewport, a boundary is in view wherever the viewport lands — by
construction instead of by arithmetic. The band the overlay counts and the band
the text draws are bounded the same way too, which the closer boundary spacing
turned from a corner case into a routine one.

Two things that fixture has to keep out of its own way, both proven by deleting
the trigger and watching the test fail: the refresh **appends** a file instead
of growing every file, so the anchor restores to the same container `y` and no
bounds-change notification re-resolves the bars for free; and the reader sits
half-way in, because `restore(_:)` forces real layout as far as the anchor, so
an anchor near the end leaves nothing estimated and no residue to catch. The
run-loop drain in the tests turns to idle rather than once, as well:
`NSHostingView.rootView` may push the document a turn later, and the
settled-layout re-resolution is queued by the layout pass that follows it — a
one-pass drain read bars nothing had resolved yet, intermittently, depending on
suite order. Recorded in
`.claude/project-memory/references/sticky-bar-resolution-paths.md` and
`headless-swiftui-layout-tests.md`.

**Tests.** `swift test` → 858 passing (2 skipped). `DiffDocumentTests`,
`DiffTextAssemblyTests`, `DiffFragmentGeometryTests`, `DiffChromeTests`,
`DiffCopyTests` and `DiffTextSurfaceTests` cover the flattening semantics, the
color-only highlight rule, the fragment→line mapping, what a selection and a
copy carry, and the drawn chrome — the last via headless
`cacheDisplay` pixel probes (tint, stripe and number colors read back against
`DiffLineStyle`'s own values, never literals). None of this was testable in the
row-based renderer.

Two of those probes capture the **composed** surface rather than one view: a
capture taken from a single view's bounds shows only what that view painted
inside them, so it is structurally blind to one view painting over another —
which is exactly how the gutter's escaping fill shipped past a green suite.
`testTheGutterPaintsNothingOverTheCodeColumn` captures the scroll view and
`testTheGutterPaintsNothingAboveItsOwnColumn` a wrapper holding the surface
under a stand-in for the panel's chrome; each was checked failing without the
fix.

**Verified live.** The renderer draws correctly in the running app on a
multi-file working tree (modified, added and deleted files, four-digit line
numbers): pinned header per file, inter-file header bands, gutter sized from the
whole document, syntax colors, and nothing painted outside the panel. A refresh
taken mid-document also lands every bar in its own band with no scroll to shake
them loose — six files of wrapping lines, the view scrolled to the fourth, then
lines inserted above the viewport.

**Still to verify.** The actively-edited-worktree check has now happened, and it
froze — see **Highlight repaint order** above. The rewrite's own feedback path
was not the cause (nothing wrote SwiftUI state during layout); the repaint's
attribute-write order was. That is fixed and covered by a test, but the fix has
**not** yet been confirmed live on an actively-edited worktree, which is the
only setup that produced the freeze. `MainThreadHangWatchdog` stays wired
(DEBUG-only) until it has.

## Open in Editor — ✅

A split-button in the title bar, immediately left of the inspector-panel toggle,
launches the workspace's worktree in VS Code, IntelliJ IDEA, or Xcode via each
editor's CLI shim (`code`/`idea`/`xed`). The button's primary action launches
whichever editor is currently selected; its attached menu lists every detected
editor, and picking one only changes which editor is current (reflected on the
primary button's label) — it does not launch anything itself.

**Detection.** `EditorLauncher.detectInstalled()` runs once at `AppModel`
startup (not live) and populates `availableEditors`: an editor counts as
detected as soon as its app bundle resolves via `NSWorkspace`
bundle-identifier lookup — the CLI shim is no longer required, since not
every editor installs one automatically. **Launch fallback.** `launch(_:at:)`
still tries the CLI shim first when it resolves on the user's **login
shell** `PATH` (`$SHELL -lc 'which <command>'`, since Casper is launched
from Finder/Dock and lacks shell-profile `PATH` additions) — it's faster and
reuses an already-open window better. When the shim is missing, it falls
back to `NSWorkspace.shared.open(_:withApplicationAt:configuration:)` on the
resolved app bundle, so an editor installed without its optional
command-line launcher (e.g. IntelliJ IDEA, which doesn't auto-install `idea`
on `PATH` the way VS Code does `code`) still launches.

**Resolution & persistence.** `Workspace.lastUsedEditor` is a per-workspace
preference. Picking a row in the dropdown (`AppModel.selectEditor`) updates it
immediately without launching anything; the primary button's launch
(`AppModel.openInEditor`) also updates it, to the editor it just launched.
`AppModel.resolvedEditor` picks, in order: an explicit kind → the workspace's
remembered `lastUsedEditor`, **but only if it is still present in
`availableEditors`** → the first detected editor. A remembered editor that is
no longer installed is never returned (it is not cleared either — if
reinstalled later, the original preference is honored again); the primary
button falls back to a working editor instead of guaranteeing a launch error.

## Per-repository config (`.casper.json`) — ✅

A repo can drop a `.casper.json` at its root (config under a `workspace` key) to
customize its workspaces. Implemented on branch `casper-json`; the setup/teardown
split lifecycle still wants one human visual pass (agents can't screenshot the
SwiftUI/terminal chrome).

**copyFiles.** `workspace.copyFiles` replaces the built-in `.env`/`.env.local`
default for seeding untracked files into a new worktree (`[]` copies nothing). An
invalid entry fails workspace creation before any Git mutation. `RepoConfig`
(CasperCore) loads/validates; malformed files surface `Invalid .casper.json: …`.

**Named commands.** `workspace.scripts` keys other than the reserved
`setup`/`teardown` are on-demand commands, run in a visible split. Triggers: a
`casper run [name]` CLI subcommand (defaults to `run`), a "Run Script"
split-button in the workspace toolbar (mirrors the editor button — primary runs
the resolved script, menu selects), and a "Run Script ▸" sidebar context submenu.
`ControlCommand.Verb.run` + `RepoConfig.resolveRunCommand` (refuses reserved
names). Listed alphabetically (JSON object key order isn't preserved by decoding);
default selection = `lastUsedScript` → `run` → first.

**Lifecycle hooks.** Reserved `setup`/`teardown` run automatically, never
invocable by hand. A surface-scoped `GhosttySurfaceView.onChildExit(UUID, Int32)`
(from `GHOSTTY_ACTION_SHOW_CHILD_EXITED`) feeds an AppModel script-surface
controller; hooks are wrapped `"<cmd>\nexit $?"` so the shell exits with the
command's status. **setup** runs from `createLinkedWorkspace` only (never on
restore) — exit 0 auto-closes its split, exit ≠ 0 keeps it open and flags the
workspace `.error`. **teardown** runs before prune (after the merge on the close
path) and ends on child-exit or a 30 s timeout, whichever first, whatever the
outcome. `AppModel.runTeardown(id:command:)` is the wait — `async`, returning a
`TeardownHookStatus` (`none`/`succeeded`/`failed(exitCode:)`/`timedOut`/
`couldNotSpawn`) — and the prune is the caller's next statement rather than a
continuation closure. Its once-latch entry carries a per-run generation, so a
timer or a child exit left over from an earlier run for the same workspace id
identifies itself as stale instead of ending the current one.
`ControlServer.handle` is reply-based so `casper workspace delete` replies after
prune (CLI `timeout: 35`). The child-exit-before-close ordering invariant and
its correctness corollaries are recorded in the `repo-config` project-memory
note.

**Docs & tests.** `README.md` documents `.casper.json` and `casper run`.

## Workspace close/delete progress — ✅

A window-modal sheet reports what a "Merge and Close Workspace…" or a "Delete
Workspace…" is doing, so a slow `teardown` hook, a large worktree or a slow
base resync no longer looks like a frozen app.

**Off the main actor.** `closeWorkspace(id:)` and `deleteWorkspace(id:)` are
`async` and return their outcome directly; every `WorktreeManager` call on those
paths runs through `AppModel.offloadGit` (a `Task.detached` hop), which is what
lets the bar animate. All model mutation stays on the `MainActor`.
`controlDeleteWorkspace(id:completion:)` keeps its completion shape for
`ControlServer` and wraps the same async core.

**Steps.** Close is 5 steps (4 without a `teardown` hook), delete 2 (1 without).
The hook's presence is resolved once up front via `RepoConfig.load`, so it
decides the step count and is handed to `runTeardown` rather than re-read there.

**The sheet.** `WorkspaceCloseProgress` (value type) +
`WorkspaceCloseProgressReporter` (delay, write-through, step numbering) +
`WorkspaceCloseProgressView`, presented by `RootView` via `.sheet(item:)`. The
reporter withholds the value for 250 ms so a fast close never flashes a panel,
and owns the shared published value **by identity**: it writes and clears only
while `closeProgress` carries its own workspace id, so overlapping runs cannot
dismiss each other's sheet. No buttons and `.interactiveDismissDisabled()` —
nothing here is cancellable midway; the one long wait, the hook, shows a 1 Hz
countdown to its timeout instead.

**One operation at a time.** `AppModel.closingWorkspaces` claims a workspace
synchronously at the entry of `closeWorkspace`/`deleteLinkedWorkspace` and
releases it in a `defer`, covering the whole operation rather than just the
teardown wait — the async conversion made an entry check meaningless on its own,
and both a menu action (a window-modal sheet does not disable the menu bar) and
`casper workspace delete` can arrive mid-flight.

**Hook failures are surfaced.** A non-zero exit or a timeout still closes or
deletes the workspace — a broken teardown never blocks deletion — but the two
GUI presenters now post an `.active` local notification for it. `.couldNotSpawn`
and the control-channel path stay log-only.

**Tests.** Full suite green (745 tests, 2 skipped). Step sequences, hook-failure
notifications, the reporter's delay and ownership rules, and two overlapping
destroys for the same workspace id are covered headlessly; the 30 s timeout path
is not (no test can reach it without waiting it out).

## Workspace info panel — ✅

`casper info set` (Markdown via `--message`, `--file`, or stdin) publishes a
message that shows up as a toolbar button next to the branch/space title;
`casper info clear` removes it.

**Control channel.** `ControlCommand.Verb.infoSet`/`.infoClear`, routed by
`ControlServer` into `AppModel.controlSetInfo(markdown:for:)`/
`controlClearInfo(for:)`. `Workspace.infoMarkdown`/`infoUnread` are transient
— excluded from `Codable` persistence like `pendingNotification` — so a
relaunch never resurrects a stale message. Setting a new message always marks
it unread; there is no coupling to the sidebar's attention flag.

**The button.** `WorkspaceInfoButton` is a bare `info.circle` glyph with no
capsule chrome — unlike its toolbar neighbours, the branch/space title
(`titleCapsule`) and the diff badge, which both draw one — sharing one
`ToolbarItem` with them so AppKit's inter-item spacing cannot push it away. It
is always mounted but collapses to a 6 pt slot (`collapsedWidth`, not all the
way to zero — that residual gap is what keeps the branch title clear of the diff
badge), zero opacity and `allowsHitTesting(false)` without a message. Unread
state is carried by the symbol fill (`info.circle.fill` at full `.primary`
strength, `info.circle` in `.secondary` once seen) plus a repeating
`symbolEffect(.pulse)` — no hue, so it never competes with the diff counter's
tints. Appearance and disappearance animate by **property** (opacity, scale,
slot width), never by a `transition`: insertion transitions do not play inside
an AppKit-hosted toolbar item, the same reason `ScriptToolbarButton` animates
its entrance from `onAppear`. Hovering reveals the panel after `hoverDelay` —
150 ms, tighter than the design's ~300 ms so the reveal still reads as immediate
to a deliberate hover while still requiring the pointer to sit still for a
moment, and still enough that crossing the toolbar never pops it open — and
dismissal waits out `dismissGrace` (250 ms) so the pointer can travel from the
button into the popover; a click reveals it immediately. Revealing the panel
calls `AppModel.markInfoSeen(for:)`, which stops the pulse. The popover anchors
on the glyph, so the chip's interior padding stays symmetric inside the button's
label and the trailing separation from the diff badge sits OUTSIDE the
`.popover` in the modifier chain — folding it back in drifts the arrow off the
icon.

**The panel.** `WorkspaceInfoPanel` renders the Markdown through a native
TextKit path, not a third-party package: `MarkdownAttributedString`
(`Sources/CasperUI/MarkdownAttributedString.swift`) turns Foundation's parsed
`AttributedString` (`interpretedSyntax: .full`, GFM) into a styled
`NSAttributedString` — headings, lists, code blocks, block quotes, and GFM
tables (via `NSTextTable`) — and `MarkdownTextView`
(`Sources/CasperUI/MarkdownTextView.swift`) hosts it in a read-only, selectable
`NSTextView`, which gives the panel both text selection and the native
pointing-hand cursor over a link (see the `nstextview-link-cursor-and-selection`
memory note). The panel carries no Copy button, unlike the design: a single
`NSTextView` answers ⌘A/⌘C over the whole message natively, unlike the earlier
`Text`-per-block renderer it replaced, so a dedicated button would only
duplicate a shortcut that already works. Images render as alt text only, so the
panel issues no network requests. The panel measures the rendered height itself
via `MarkdownTextView.height(for:width:)` and hugs it up to `maxHeight`, then
scrolls; an `http(s)` link opens in the workspace's own browser panel instead of
leaving the app, unless `systemBrowserModifier` (⌘) is held, which sends it to
the system's default browser. That routing is a pure decision
(`WorkspaceInfoPanel.destination(for:modifiers:)`) so tests can pin the
⌘ branch without a browser really launching; `MarkdownTextView` stays generic
and only reports the flags, read off `NSApp.currentEvent` because AppKit's
`clickedOnLink` callback carries no event of its own.

**Tests.** Headless `NSHostingView` layout tests cover the empty/non-empty
button states and that `AppModel.markInfoSeen` clears `infoUnread`
(`WorkspaceInfoButtonTests`; no headless click or hover-dwell drives the
button's own `reveal()`, so this pins the model primitive it calls, not the
button), alongside the earlier control-channel/model
tests (Tasks 1–3), `MarkdownTextViewTests` and `MarkdownAttributedStringTests`
(the TextKit renderer and its hosting view), and `WorkspaceInfoPanelTests`
(layout smoke tests for the panel's Markdown rendering). The visual
hover/pulse/link-cursor/link-routing pass needs a human — see the
`agent-visual-verification-limits` memory note.

## Developer tooling (`#if DEBUG`)

- **Debug & observability channel — ✅.** `DebugProtocol`/`DebugSocket`/
  `DebugServer`/`DebugCLICommand`; nine verbs — `dump-state`, `read-text`,
  `send-text`, `send-keys`, `send-key`, `send-action`, `mouse-move`,
  `screenshot`, `focus`. As-built deviations are recorded in `themes/debug.md`.
- **Debug surface addressing — ✅.** Stable surface `id`, `focus` verb,
  `--target` option.

Gated entirely at compile time; physically absent from `make release`.

## Space (project) — ◐
The **Space** model shipped with CasperUI UI-2 (`Session → Space → Workspace`;
`repoPath` up to `Space.folderPath`; `Workspace.kind`/`baseBranch`; Space-grouped
sidebar; `Repository.remoteURL` + `origin` name derivation). What remains for this
feature is **Space rename** only.

The per-workspace **`+/−` diff summary** (branch-vs-merge-base divergence badge)
is **dropped** (decision 2026-07-06) — the title-bar working-tree-vs-HEAD summary
covers the need. The old task-by-task plan (`plans/space-project.md`) is
superseded: its model/remote/naming tasks landed with UI-2, and its divergence
tasks are moot.

## Agent-state detection — ◐
Infers `Workspace.agentState` (`working | blocked | idle | done | unknown |
error`) by scraping the terminal, no hooks. Design: `themes/agent-state-detection.md`.

**Built & live-verified:** the pure engine (`CasperCore/AgentDetection.swift` —
data-driven matchers for both the viewport (`blocked`) and the OSC title
(`working`/`idle`), most-urgent aggregation, debounce/`done`-latch resolver, 29
tests); non-DEBUG `readViewportText()` and `readOSCTitle()` accessors (the latter
fed by `GHOSTTY_ACTION_SET_TITLE` captured per-surface); the `AppModel` timer
(~250 ms) that scrapes each workspace's terminals — viewport **and** title —
resolves, and writes `agentState` unless the workspace is under explicit
authority; the `casper status set` authority latch (transient) that stops
detection for that workspace; and the sidebar status icon (`WorkspaceRow`,
monochrome outline SF Symbols in the chevron column, animated `working`). Live
GUI check confirmed idle→working→idle, driven by the real OSC-title spinner
(current Claude Code's `working` marker), plus `blocked` from the viewport.

`done` is produced by the resolver's own `working → idle` derivation. `blocked`/
`done` (and `error`, for the explicit-only path) are wired to `casper notify` +
`pendingNotification` (`AppModel.controlRaiseNotification`), with an
interruption level (`.passive` for `done`, `.active` for `blocked`/`error`) and
a per-workspace 3s de-dup cooldown against near-simultaneous explicit/detected
notifies for the same event. See
`plans/notification-idle-best-practices.md`.

**Not implemented (by decision):** a process-exit (`childExited`) `done`/`error`
producer + authority release. It was believed to only fit an *agent-as-command*
surface that Casper couldn't create — but `command` is not actually inert: the
embedded libghostty (a sandbox/host-managed fork) execs it via a hardcoded
`bash -l -c "exec <command>"`, regardless of the user's real login shell, which
does replace the shell process. This reopens the *agent-as-command* option; it
hasn't been re-evaluated since. The `--command` reliability fix itself has
shipped; the queued text is typed into the already-spawned login shell via
`ghostty_surface_text` (libghostty's own `initial_input` field is left null —
it mojibakes non-ASCII; see [[ghostty-initial-input-utf8]]), with no `exec`, so
it does not itself enable an agent-as-command surface.
Agents currently still run inside a shell; `error` has no detected producer and
authority release is deferred to the timeout mechanism (option B). The initial
implementation was removed. See the theme's "Process lifecycle" section.

**Deferred:** `.render`-driven trigger (timer poll for now); option-B timeout
authority release; per-surface status (option B); agents beyond Claude Code
(per-agent rule sets).

## Dock bounce + unread badge — ✅

Carries the sidebar's attention dot out of the app and onto the Dock icon, so a
`blocked`/`done`/`error` workspace is noticed while Casper is in the background.
Design: `themes/app-ui.md` § Design → "Dock attention".

**Built.** `CasperUI/DockAttention.swift` — a `DockAttentionPresenting`
protocol (`bounce()`, `cancelBounce()`, `updateBadge(count:)`) over a
`DockAttentionBackend` protocol (is-active, request/cancel attention, badge
label) whose production implementation drives `NSApp`. The presenter is
injected into `AppModel` as `dockAttention`, alongside the existing
`deliverNotification` / `isWindowKey` seams, so the wiring is testable
headlessly; the backend seam does the same one layer down, for the request-id
latch itself. `AppModel.refreshDockAttention()` counts `pendingNotification`
across every Space, pushes it to the badge, and cancels the bounce at zero; it
is derived state and writes nothing, so it adds no `persist()` and no
`@Observable` write. Called from the arming branch of
`controlRaiseNotification`, from `clearNotificationForFocusedWorkspace` and
`clearNotificationOnResume`, and from the three paths that drop a workspace
(`removeWorkspace`, `removeSpace`, `addSpace`'s `reunify` — the shared `retire`
runs before `spaces` settles, so it can't own the refresh itself).

The bounce is `.criticalRequest` (bounces until activation, not once) and starts
**only** on the edge that arms a bubble — a later focus loss must not re-bounce.
It is also never requested while Casper is the active application: AppKit says
so, and since the arming edge is not focus-gated (a notification for a
non-selected workspace arms with the window key), a request latched in front
would be released by nothing and would swallow the next real bounce. Both
`AppDelegate.applicationDidBecomeActive` and `applicationDidResignActive` call
`AppModel.releaseDockBounce()`, which cancels the request and deliberately
leaves the badge alone: the badge is an unread counter that counts down per
workspace, not per activation.

Sixteen tests (`DockAttentionTests.swift`): eleven drive the `AppModel` matrix
through a recording spy — including the `addSpace`/`reunify` drop path and the
cancel-without-touching-the-badge release — and five drive `DockAttention`
itself against a fake backend, pinning the latch, the id handed to the cancel,
the badge's zero → no-label mapping, and the never-bounce-while-active rule.

## Remaining work — dependency-ordered

1. **CasperGit `git_diff` — ✅ built** (`diffWorkdirToHead()`); the diff viewer is
   unblocked.
2. **CasperUI (Plan 5) — ✅ built.** All of UI-1..UI-5 (app shell + startup wiring;
   Space model + Space-grouped sidebar + linked Git worktrees; recursive
   splits/tabs layout; WKWebView browser surface; read-only diff viewer). The live
   GUI verification pass on a real desktop is complete.
3. **Space rename** — the Space data-model change and sidebar grouping landed in
   UI-2; what remains is renaming a Space from the sidebar. (The `+/−` diff
   summary that used to live here is **dropped** — decision 2026-07-06.)
