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

| Plan | Module | Status |
| --- | --- | --- |
| 1 | CasperCore | ✅ |
| 2 | CasperGit (+ Clibgit2) | ✅ worktrees/status/`remoteURL`/`git_diff` built |
| 3 | CasperCLI + CasperAgents | ✅ |
| 4 | CasperGhostty | ✅ one terminal + splits/tabs composed by UI-3 |
| 5 | CasperUI + app | ✅ UI-1..UI-5 built (sidebar + worktrees + splits/tabs + browser + diff); live GUI check done |

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
  end-to-end against a live page. See the `browser-console-capture` memory note.
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
`GhosttyRuntime`, `GhosttyAction`, `GhosttySurface`, `GhosttySurfaceView`,
`GhosttySurfaceRepresentable`, `GhosttyDemo`, `GhosttyMenu`,
`GhosttyActionDispatcher`. Rendering is display-link driven, so
`GHOSTTY_ACTION_RENDER` needs no explicit `draw()` wiring.
- **Keyboard & clipboard — ✅.** Control/Option/⌘ combos all work (Ctrl-C/D,
  ⌘C/⌘V/⌘A via NSPasteboard, ⌘±/0 font size, ⌘Q, ⌘W); macOS menu bar
  (App/Edit/View/Window); `macos-option-as-alt` wired (inert in the pinned
  binary). ⌘-key/menu paths confirmed by structure + live keypress (the debug
  channel bypasses `performKeyEquivalent`).
- **Mouse — cmd+click opens URLs — ✅.** libghostty forwards the ⌘ modifier and
  emits `GHOSTTY_ACTION_OPEN_URL` when a terminal link is cmd+clicked; the action
  decodes into `GhosttyAction.openURL` and opens via `NSWorkspace`, matching
  upstream Ghostty (any parsable URL, no scheme restriction).
- Remaining for CasperUI: splits/tabs layout composition (actions are decoded
  and routed through `GhosttyActionDispatcher`, but not composed into a layout —
  **UI-3**; UI-1 renders only the single-terminal case); clipboard
  paste-confirmation UI (v1 auto-confirms); `flagsChanged` press/release
  semantics and scroll precision/momentum.

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
the sidebar/content edge), then `InspectorPanel` at a state-driven `width` (default 480,
clamped 240–1400) shown only when expanded. The `Divider()` doubles as a drag handle
(transparent 10 pt hit area, left-right resize cursor) that resizes the panel; the
width lives in view `@State`, so it is **preserved across collapse/expand** and,
because the left region stays `maxWidth: .infinity`, **unaffected by adding
terminals**. It is a side region, not an `HSplitView` pane (which would reset the
width on re-add). Width is not yet persisted across workspace switches or restarts. `InspectorPanel` is a native segmented Browser|Diff
selector pinned to the top over **full-bleed** content (no insets — a native
`TabView`'s mandatory content inset was rejected), reusing `BrowserSurfaceView` (on
`inspector.browser`) and `DiffSurfaceView` unchanged. The panel is collapsed only
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
- `DiffStickyHeader.swift` — an overlay reproducing `pinnedViews:
  [.sectionHeaders]`, including the push behaviour. It only **reads** geometry
  and feeds nothing back into text layout.
- `DiffTextSurface.swift` — `NSViewRepresentable` owning the scroll view, the
  explicit TextKit 2 chain, the ruler and the overlay, with a narrow imperative
  API (`apply(document:restoring:)`, `applyHighlight`, `scroll(toFileID:)`,
  `currentAnchor()`).
- `DiffSurfaceView.swift` — SwiftUI, orchestration only: refresh, dedup,
  progressive highlighting, scroll target, empty states.

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

**Tests.** `swift test` → 846 passing (2 skipped). `DiffDocumentTests`,
`DiffTextAssemblyTests`, `DiffFragmentGeometryTests`, `DiffChromeTests` and
`DiffTextSurfaceTests` cover the flattening semantics, the color-only highlight
rule, the fragment→line mapping, and the drawn chrome — the last via headless
`cacheDisplay` pixel probes (tint, stripe and number colors read back against
`DiffLineStyle`'s own values, never literals). None of this was testable in the
row-based renderer.

**Still to verify.** Live confirmation on an actively-edited worktree with the
diff panel open — the only setup that has ever exercised the hang this rewrite
removes. `MainThreadHangWatchdog` stays wired (DEBUG-only) until that lands.

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

**Docs & tests.** `README.md` documents `.casper.json` and `casper run`. See the
ledger (`.superpowers/sdd/progress.md`) for the per-task history.

## Workspace close/delete progress — ✅

A window-modal sheet reports what a "Merge and Close Workspace…" or a "Delete
Workspace…" is doing, so a slow `teardown` hook, a large worktree or a slow
base resync no longer looks like a frozen app. Design (gitignored scratch, like
the ledger): `.superpowers/sdd/2026-07-26-workspace-close-progress-design.md`.

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

## Developer tooling (`#if DEBUG`)

- **Debug & observability channel — ✅.** `DebugProtocol`/`DebugSocket`/
  `DebugServer`/`DebugCLICommand`; verbs `dump-state`/`read-text`/`send-text`/
  `screenshot`. As-built deviations are recorded in the observability spec §6.
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
does replace the shell process (see [[surface-command-bash-exec]]). This
reopens the *agent-as-command* option; it hasn't been re-evaluated since. The
`--command` reliability fix itself (typed via `initial_input`, no `exec`) has
shipped; it deliberately does not use `exec`, so it does not itself enable an
agent-as-command surface.
Agents currently still run inside a shell; `error` has no detected producer and
authority release is deferred to the timeout mechanism (option B). The initial
implementation was removed. See the theme's "Process lifecycle" section.

**Deferred:** `.render`-driven trigger (timer poll for now); option-B timeout
authority release; per-surface status (option B); agents beyond Claude Code
(per-agent rule sets).

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
