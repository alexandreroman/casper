# Theme: App & UI (CasperUI)

**Module:** CasperUI · **Status:** ✅ built (see `../status.md`)

The SwiftUI app that turns the built modules into the real product. The diff
viewer depends on CasperGit `git_diff` (`git-worktrees.md`); the pane layout
depends on Ghostty layout composition (`terminal.md`).

## Design

- **App shell** — a SwiftUI `App` scene with an `NSApplicationDelegateAdaptor`,
  and one `@MainActor @Observable AppModel` as the single state owner and the
  bridge to the other modules; the window is a `NavigationSplitView` with an
  empty state. Casper owns the menu bar through SwiftUI `.commands`
  (`terminal.md` § Design → "Main menu"), **replacing** the standard command
  groups; the Window menu and the rest of the App menu are SwiftUI's defaults.
  The only `NSMenu` built in AppKit is the pane context menu
  (`PaneContextMenu`). See "Menu bar" below.
- **Menu bar** — one menu per object level, each acting on the selection, in
  the order App, Space, Workspace, Edit, View, Window:

  ```text
  Space                Workspace                       View
  New Space…    ⇧⌘N    New Workspace…    ⌘N            Show Sidebar  ⌃⌘S
  Add Folder…    ⌘O    ───                             ───
  ───                  Show in Finder                  Diff     (checkmark)
  Remove Space…        Open in Editor                  Browser  (checkmark)
                       Run Script                      ───
                       ───                             Split Up / Down / …
                       Copy Workspace Path
                       Copy Branch Name
                       ───
                       Merge and Close Workspace…
                       Delete Workspace…
  ```

  **Space** is the standard File slot retitled (see "Ways into a Space");
  **Remove Space…** acts on the selected workspace's Space. **Workspace** acts
  on the selected workspace, and sits right after Space so the two object menus
  read project, then worktree; its shared items render the same
  `WorkspaceMenuItem` description as the sidebar row's context menu. It is the
  one additive `CommandMenu`, which SwiftUI always lands between View and Window
  — `.commands` offers no way to place it elsewhere — so the AppKit resync that
  retitles File → Space also moves it after Space on every update pass
  (`AppDelegate.placeWorkspaceMenuAfterSpaceMenu(in:)`,
  [[swiftui-mainmenu-miniaturize-resync]]). The same resync's strip of empty
  Format/Help stubs exempts it, since SwiftUI fills a `CommandMenu` only when it
  is opened. **Edit** holds the standard Copy, Paste and Select All only.
  **View** adds the inspector's Diff / Browser toggles and the pane splits after
  SwiftUI's standard Show/Hide Sidebar (`SidebarCommands`); "Check for Updates…"
  is the App menu's one addition (see "Software update").

  The menu body observes **no volatile state** — no selection, no focus, no
  per-workspace data — because SwiftUI re-asserts the whole native menu each
  time that body is invalidated, which flickers the bar
  ([[swiftui-mainmenu-miniaturize-resync]]). Every enable-state and the Diff /
  Browser checkmark read an edge-triggered `menu…` flag on `AppModel`, written
  only when its value flips, and every action resolves the selected workspace
  when it fires. That is why **Open in Editor** and **Run Script** are plain
  items rather than the title bar's submenus — a submenu listing the selected
  workspace's editors or scripts would observe the selection. Each runs what
  the matching title-bar chip's primary action runs: the resolved editor
  (`openInEditor(nil, for:)`) and the resolved script (`runResolvedScript`),
  the latter disabled while the workspace's `setup` hook runs. The Diff /
  Browser checkmark is the selected workspace's `InspectorState.visibleTab`;
  it moves only on a user toggle or a selection change, the same discrete
  edges the enable-state flags flip on.

  **Remove Space…** — in this menu and in the sidebar's Space header context
  menu — asks first (`presentRemoveSpaceConfirmation`): removing a Space
  closes every terminal of its workspaces, though nothing on disk is touched.
  `removeSpace(id:)` itself asks nothing, since it is also driven headlessly.
  The menu-bar item is disabled while any workspace of that Space is being
  closed or deleted: the operation's progress sheet blocks the sidebar but not
  the menu bar, and a Space removed mid-merge would leave the worktree and
  branch on disk and the primary worktree un-resynced.
- **Appearance** — the app follows the system Light/Dark appearance; nothing
  forces one. `AppDelegate` observes `NSApp.effectiveAppearance` and forwards it
  through `AppModel.applyColorScheme(dark:)` to libghostty (the app and every
  live terminal view, the background nursery's included). The scheme is also set
  before `model.runtime` is assigned, so the first surface is born on the right
  side. Diff colours are dynamic and syntax highlighting re-runs on a scheme
  change.
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
  and **one** caption line. The bar fills through the step in progress —
  (completed + in-progress) ÷ total — so the last step at work shows a full
  bar. `RowDisplayState` composes that caption, preferring the
  pending-notification message over the current `in_progress` todo label — the
  more urgent signal wins, and stays up until the notification clears — and
  falling back to `"Done"` once every todo is complete. There is no numeric
  `completed/total` text. Nothing in the row carries a hue of its own: selection
  tints every glyph and label white on the accent pill. The `AgentStatusIcon`
  glyphs and the caption stay monochrome throughout — but the row is not: the
  notification dot is blue (white while selected), and the `ProgressBar` turns
  green once every todo is complete.
- **Ways into a Space** — two of them, offered in the same order wherever they
  appear: **New Space…** (⇧⌘N) creates a project from nothing, **Add Folder…**
  (⌘O) adopts one that already exists; plain ⌘N belongs to **New Workspace…**,
  the thing created most often. They open the **Space** menu; they are the empty
  state's two buttons, create prominent and adopt merely bordered, since a user
  with nothing open is likelier to be starting something than to be hunting for
  a repo they forgot to add; and they are the two rows pinned below the
  sidebar's scrolling list, create above adopt. All three sites render one
  `SpaceEntryCommand` description and list its `allCases`, so titles, symbols,
  actions and order cannot drift apart.

  **New Space…** asks for a name *and* a location in **one** `NSSavePanel`
  (`AppModel.presentCreateSpacePanel`), rather than a name prompt followed by a
  folder picker: a save panel is the native shape of "name this and say where it
  goes", and its standard **New Folder** button comes with it for free. The
  panel reopens at the location last used — the *parent* folder, not the Space
  itself — carried in `Session.lastNewSpaceLocation` and written to
  `session.json`, because Casper stores no preference of its own in
  `UserDefaults` — the single key it reads there is a *system* setting,
  `AppleActionOnDoubleClick` (see "Title bar") — and the session file is where
  a preference of Casper's own belongs. An absent key decodes to nil, and a
  remembered folder no longer on disk is ignored rather than aiming the panel at
  nothing.

  `AppModel.createSpace(at:probe:)` then does the work: create the directory,
  `git init` it through `CasperGit`'s `Repository.initialize`, give it one
  **empty initial commit** (`Repository.createInitialCommit`), and hand it to
  `addSpace(folderURL:probe:)` — so what comes out is an ordinary Space with one
  primary workspace, indistinguishable from an adopted one. That commit carries
  no files at all: what a project starts with is still the user's call, no
  README and no `.gitignore`. It exists so the Space can host a workspace from
  its first frame — `git worktree add` checks the new worktree out at a commit
  resolved through HEAD, and `git init` alone leaves HEAD unborn, resolving to
  nothing (`space-project.md`). Casper never invents a committer to get it: when
  neither `user.name`/`user.email` nor the environment names one
  (`git-worktrees.md` § Design → "Commit identity") the commit is skipped, the
  Space is created anyway, and creating a workspace in it is what says so.

  **Casper never deletes or overwrites what it did not create.** A directory
  already at the chosen path is accepted only when it holds nothing but a
  `.DS_Store` — which is exactly what the panel's own **New Folder** button
  hands over — and anything else is refused with
  `CreateSpaceOutcome.Failure.pathOccupied` and an alert that says why. That
  covers the one panel behaviour deliberately not honoured: `NSSavePanel` runs
  its own "…already exists. Replace?" sheet and, on Replace, simply returns the
  URL, expecting the caller to overwrite. Casper refuses instead, so confirming
  Replace costs the user nothing. Rollback is scoped the same way — a failed
  `git init` or adoption removes a directory *this call* created, and inside a
  directory the user handed over it removes only the `.git` Casper initialized,
  leaving the directory itself. That `.git` has to go too: left behind it makes
  the very same path un-creatable on a second attempt, `isVacant` refusing a
  folder the Finder still shows as empty.

  Like `addSpace`, `createSpace` runs no modal of its own (it is also driven
  headlessly, by the tests), so every failure — `pathOccupied`,
  `directoryNotCreated`, `repositoryNotInitialized`, `notAdopted` — is put on
  screen by the presentation layer. `notAdopted` carries the adoption failure
  verbatim, so the two entry points never word one problem two different ways.

  One structural consequence: `AppDelegate.renameFileMenu(in:)` recognizes the
  standard File menu by its submenu's **first item title**, in order to retitle
  it **Space**. That marker is `CasperCommands.newSpaceTitle`, which must stay
  the first item of the `.newItem` group: a command placed ahead of New Space…
  breaks the rename unless the constant names it instead.
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
  pane to the nearest-edge zone a drag would land in). The last two back pane
  **drag-and-drop** — `PaneDragAndDrop.swift` owns the grip, the drag session
  and the drop overlay, surfaced by `SurfaceHostView`/`SplitContainerView`; see
  [[intra-app-drag-pasteboard-type]].

  Splits render through the custom `SplitContainerView`, which lays panes out by
  fraction along the axis. A separator is a drawn 1 pt hairline with a wider
  **transparent** grab strip over it, carrying the resize cursor and the drag
  without reserving visible width — native `HSplitView`/`VSplitView` draw a
  near-black divider. Both measures come from `SeparatorMetrics`, the one
  contract the inter-pane, inspector and inspector-edge separators all read, so
  they cannot drift apart. The grab strip is a concrete `NSView`: a SwiftUI
  `.pointerStyle` loses the cursor to the terminal surface's own `cursorUpdate`
  ([[terminal-overlay-cursor]]). Panes are placed with explicit non-overlapping
  frames, because libghostty's `CAMetalLayer`-backed terminals ignore SwiftUI
  `.opacity` and would occlude one another. Right-clicking a pane opens the
  split/copy/paste/close menu.

  Surface views live in a persistent cache keyed by `Surface.id`, so a PTY
  survives split, collapse and reorder; only the layout may bring a view into
  existence, so a `Surface` value the tree no longer holds cannot refill the
  cache ([[surface-view-layout-membership]]). Pane fractions seed from the
  layout's persisted `ratios` and are written back through
  `AppModel.setSplitRatios` → `LayoutTree.updateRatios` (debounced save) on
  drag-end and on double-click-to-equalize, so a resize survives relaunch. The
  `LayoutActionHandler` routes libghostty's split and tab actions to the
  **focused** workspace, tracked through the surface's first-responder callback.
  Closing the last surface re-seeds the workspace with a fresh terminal instead
  of closing it, so panes alone never remove a workspace or a Space.
- **Diff viewer** — a read-only surface backed by libgit2's `git_diff`
  (structured hunks/lines, working tree vs HEAD), rendered as **one TextKit
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
  A `casper diff open <file>` scroll request is one-shot: the view clears it
  once the surface takes the scroll, or once a diff computed after the request
  does not list the file (matched by exact worktree-relative path), so an
  unchanged file opens the diff without scrolling and a remount never scrolls
  again. A surface the request has just mounted holds the scroll until the
  layout that first sizes its viewport. A scroll right after a refresh — that
  request, or the reader's place restored across the swap — reaches a file the
  refresh pushed past the previous diff's end.

  The document carries per-file sections (path + status, binary and unreadable
  files noted), hunk headers, and code rows tinted by kind (green addition / red
  deletion / neutral context), with a single line-number column (old for
  deletions, new otherwise). It is computed on open and **live-refreshed** by
  **two** native FSEvents watchers on the selected workspace, both funnelling
  through one 0.2 s debounce (`diffDebouncer`) that bumps an observable revision
  the diff surface and the title-bar `+/−` badge react to: one on the worktree
  folder (`.git` and Git-ignored top-level dirs excluded), and one on the
  resolved gitdir's `logs` reflog directory, which is what catches a commit.
  Both stop while the window is hidden and re-arm when it comes back
  ([[diff-refresh-two-watchers]]).
- **Browser** — a `WKWebView` surface (address bar with bare-host
  normalization, back/forward/reload), aimed at previewing a `localhost:PORT`
  app started by the agent. No Chromium. The web view is owned by its
  `BrowserCoordinator`, cached in `AppModel.browserCoordinators` by
  `Surface.id`, so the page and its history survive the inspector collapsing
  and switching tabs.

  The address bar and the page itself persist the URL through **one** path:
  `BrowserCoordinator` reports every navigation through `onCommitURL`, wired by
  `AppModel.browserCoordinator(for:)` to `AppModel.setBrowserURL`, which no-ops
  when the stored URL already matches so a page load cannot thrash
  `session.json`. An address-bar `load` changes the web view's `url` inside the
  call, so the report lands before it returns. The control channel's
  `browser open`/`load` bypass it: they write the stored URL themselves, then
  load and save it. Same-document navigations need KVO rather than the
  navigation delegate — see [[webkit-page-driven-navigation]].
- **Inspector panel** — a collapsible right-side panel on the workspace detail
  view with two tabs (Diff | Browser, in that order), per workspace and
  persisted (`Workspace.inspector`). It reuses the browser and diff surfaces
  rather than replacing them.

  **The inspector is the only home for both.** There is no diff surface kind,
  and `Surface.Kind.browser` is reached only through
  `Workspace.inspector.browser`: splits always create a terminal
  (`PaneContextMenu`), there is no "New browser" menu item anywhere, and
  `AppModel.surfaceView(for:in:)` returns a view only for `case .terminal` — so
  a `.browser` leaf that did reach the layout tree would render as the
  `textBackgroundColor` placeholder `SurfaceHostView` paints when no view
  resolves. Such a leaf survives only as a legacy `session.json` decode; nothing
  in the app creates one.

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
- **Window floor** — the terminal region (the pane splits, not the sidebar and
  not the inspector) has a calibrated minimum of **200 × 200 pt**, and the
  window's own floor follows from it: `WindowFloor` computes it from the
  sidebar's width plus the inspector's, plus that minimum, and pushes it to
  **both** of the window's minimums — `contentMinSize`, and the frame-based
  `NSWindow.minSize` derived from it. It also grows a window already below the
  floor, because `contentMinSize` constrains a drag but never grows a window
  that is already under it — otherwise revealing the inspector on a small window
  would leave the terminal squeezed instead of widening it.

  A SwiftUI content minimum does **not** reach `NSWindow`, not even declared on
  the sidebar column, so the floor cannot be expressed in the view tree. And
  `WindowGroup` recomputes `contentMinSize` from its content on every view
  update and writes it back (228 × 142, crediting the sidebar 28 pt where it is
  300), clobbering a value written only there within the frame. So the
  **frame-based `minSize` is what holds** — it is the one SwiftUI does not
  manage — and the floor is re-applied on every window update besides. The
  authoritative mechanism is `NSWindowDelegate.windowWillResize(_:to:)`,
  deliberately **not** taken because it means taking the window's delegate away
  from SwiftUI: the accepted consequence is that the floor holds from normal
  states but not from a window already collapsed below it, which normal use does
  not reach.

- **Title bar** — the workspace toolbar is **one** `ToolbarItem`, holding the
  whole row: the title capsule, the info chip, the diff badge, the Merge chip
  (only for a linked workspace with a base branch), the Run Script chip (only
  with named commands in `.casper.json`), the Editor chip (only with a detected
  editor) and the `InspectorTabSelector`.

  One item is not a grouping preference, it is the only structure that cannot
  reach AppKit's overflow chevron — where these custom chips render without
  their capsule chrome and the segmented control clips to a lone glyph. AppKit
  sizes a toolbar item to its content's **ideal** width and will not propose it
  less: too little room and it overflows the item **whole**, the truncatable
  ones included (measured in [[toolbar-overflows-before-squeezing]]). Any item
  AppKit can single out is an item it can overflow, so the row hands it a single
  item that is never wider than the bar and does the degrading itself.

  Spanning the bar costs the row two `NSThemeFrame` behaviours, so the row hands
  both back to itself, on a clear layer **behind** it (a `.background`) rather
  than on the row. On the row they would be gestures on an ancestor of every
  chip, and SwiftUI holds a child button's press until those rule themselves
  out — the double-click above all — so every chip's pressed state would lag the
  pointer. As a sibling, the layer receives only the clicks no chip claims: the
  spacer between the groups, the gaps, the info button's collapsed slot, and the
  title, which opts out of hit testing so its clicks fall through. **Dragging
  the window** is a `WindowDragGesture` on that layer, under a
  `.contentShape(Rectangle())` because neither a clear colour nor a `Spacer`
  claims hits of its own. **Double-clicking the title bar** is an
  `.onTapGesture(count: 2)` running `TitleBarDoubleClickAction`, which honours
  the choice made in System Settings (Fill, Zoom, Minimize and Do Nothing are
  all real answers) instead of zooming unconditionally, and turns away a window
  that would only beep. Placement is what keeps a chip's own click intact, and
  what keeps a double-click on a chip from zooming the window; both gestures
  stay plain. The layer takes the hosted row's rect rather than the toolbar
  item's full height, which is what leaves the window's top-edge resize band
  with the theme frame ([[titlebar-row-window-drag]]).

  That width is the one measured number in the row. It comes from the detail
  area's `GeometryReader` — never from content that can overflow its column,
  which reports a width the column never had — minus the window chrome
  when the detail starts at the window's leading edge
  (traffic lights and sidebar toggle share the row only when the sidebar is
  collapsed, which the frame's origin is what reveals), minus a safety margin.
  It **undershoots on purpose**: a row narrower than the bar leaves a few
  invisible points at the right, a row wider than it empties the entire title
  bar. Below a floor the item leaves the toolbar rather than overflowing it.

  That standing margin covers a **still** window only. AppKit's item viewer
  starts 8 pt inside the detail area, so two thirds of the 24 pt is real slack
  — measured: detail area at `minX = 228`, the item's hosted view at
  `minX = 236`, a 1148 pt row in a 1400 pt window content, which leaves 16 pt
  at the trailing edge — and a drag that narrows the window by more than that
  slack per layout pass eats it whole. The declared width is derived from
  `@State`, so it is always one pass behind the window, and the stale value is
  the one AppKit judges. A moving window therefore buys a **second** term: the
  shrink measured on the previous pass, subtracted from the width the row
  declares, so that the stale value already fits the bar of the pass that
  follows. It is **clamped at the mount floor** — an item that unmounts and
  remounts once per frame is a worse artifact than the overflow it prevents.

  Three properties keep that second term safe on a drag done with the pointer,
  and the first two rest on facts only a real drag shows. SwiftUI **coalesces
  layout passes**, so a measured delta is a distance, not a rate: it is the
  whole distance travelled since the last pass and it is unbounded (a traced
  990 → 428 pt drag arrived as **one** pass of 562 pt). So the term is
  **capped** at 40 pt — twice the fastest ordinary pass, and just under one `⋯`
  chip plus its gap — because past that bound the right answer to a jump
  nothing could anticipate is the single frame of chevron the heal already
  recovers, not a row collapsed onto the ladder's floor. It is **ratcheted**
  while the window is in a live resize, growing only, because the declared
  width must be **monotone while the window narrows**: the ladder below is
  chosen from it, so a width that falls and rises again brings the badge, the
  Space name and the chip labels back mid-drag — the non-monotone degradation
  the single ordered ladder exists to prevent, arriving through its one input.
  And it is **given back only once the drag has ended** — a hand-driven drag is
  bursts of passes separated by pauses longer than the settle delay, so the
  debounce waits again while the resize is still live rather than releasing
  into a pause for the next burst to take away. A jump outside a live resize (a
  zoom, a programmatic resize) has no drag to stay monotone across, so the
  capped shrink applies as-is and is anticipated once.

  Measured with the `CASPER_RESIZESTEP` probe over a shrink phase (chevron up
  at the instant AppKit lays out): without the second term, 18 of 19 steps at
  40 pt per step, 6 of 8 at 16 pt and 1 of 14 at 8 pt. With it, the rule is the
  cap: at or below 40 pt per step the chevron comes up on the drag's **first**
  step only (1 of 19 at 40 pt per step), because no shrink has been measured
  yet on that pass, while **above** the cap it comes up on every step — a
  120 pt step declares `settled − 40` against a bar that fell 120. The probe
  drives `setFrame`, so `inLiveResize` is false and the ratchet never applies:
  each step stands alone. A growing window raised the chevron at no step size
  either way: the lag leaves the row too narrow there, which nothing can see.

  That residual is what the cap buys, and it was chosen deliberately over a row
  that folds for the whole drag. A hand-driven drag traced over 485 samples
  shows it in proportion: 8 chevron frames, every one of them on a coalesced
  pass of 97–558 pt, against 0 releases while the drag was live, a peak
  undershoot of 40 pt, a narrowest declared row of 136 pt, and no rung climbing
  back up the ladder while the window narrowed.

  What the anticipation cannot cover is left to the **heal**, which invalidates
  the toolbar items' intrinsic size (the one thing that makes AppKit re-run its
  fit check) and retries while the clipped-items indicator stays up. Beyond a
  pass wider than the cap, two jumps need it: one with no previous pass to learn
  from (a zoom, a display change), and **collapsing the sidebar**. The chrome
  reserve is charged on `detailFrame.minX < 1`, so a collapse drops the declared
  width by ~140 pt on a pass whose detail area *grows*: the shrink term computes
  zero and AppKit judges the previous, wider row against a bar that has just
  lost its leading 140 pt. Expanding is the safe mirror image. Deriving the
  shrink from the chrome-adjusted widths would cover the collapse, but would
  hold ~140 pt of undershoot for the whole settle delay and visibly fold the
  chips on every collapse — worse than one frame of chevron that heals itself.
  Pre-arming a budget on `willStartLiveResizeNotification` was rejected on the
  same grounds: it cannot know the drag's direction, so it would fold the chips
  at the start of every **grow** drag, where no artifact exists, to save one
  frame at the start of a shrink that the heal already catches.

  **The row degrades along ONE ordered ladder**, widest first, and everything
  that yields is a rung of that same list. The full action row is
  `( ⤭ Merge )( ▶ Run )( icon Editor ⌄)( ± │ 🌐 )`:

  | rung | title          | badge | actions                |
  | ---- | -------------- | ----- | ---------------------- |
  | 1    | Space / branch | yes   | full row               |
  | 2    | Space / branch | —     | full row               |
  | 3    | branch         | —     | full row               |
  | 4    | branch         | —     | `( ⤭ )( ⋯ )( ± │ 🌐 )` |
  | 5    | branch         | —     | `( ⋯ )( ± │ 🌐 )`      |
  | 6    | branch         | —     | `( ⋯ )`                |

  The order encodes what each element is worth: the diff badge is
  **informational** and goes first, the Space name is **context**, the chip
  labels are **actions**, and the branch is **identity** and never drops. One
  list rather than one ladder per element, because **a second decision-maker
  makes the degradation non-monotone** — measured three times over: a badge
  that vanished at 500 pt came back at 260 pt beside a folded chip, a badge
  ranked by layout priority came back the moment the chips folded, and a title
  running its own `ViewThatFits` dropped its Space name, handed ~90 pt back and
  brought the selector back at 279 pt as the window got *narrower*. Elements
  cannot be ranked against each other except by being rungs of the same list.
  Within a rung the branch still middle-truncates — that is `Text` under a
  proposal, not a second ladder.

  Run and Editor have **no glyph-only form**: they go from full text straight
  into the `⋯` menu. Only Merge and the selector have a glyph form on the bar.

  The **`⋯` menu** lists exactly what is not on the bar, without exception, so
  its contents vary by rung and never duplicate a visible chip — `Inspector`
  appears only at the last rung, where the selector itself has folded into the
  menu. Its order mirrors the chips' order on the bar
  (Merge/Delete, `Run Script` ▸, `Open in Editor` ▸, `Inspector` ▸) so the
  folded menu reads like the row it replaces; the two orders are coupled and
  change together. The submenu is named `Inspector` after the **panel on the
  right**: macOS reserves "Sidebar" for the left workspace column. Its items,
  `Diff` and `Browser`, route through the same `toggleInspectorTab` mutator as
  the segments, checkmarked against the tab showing, so bar and menu cannot
  disagree. The View menu's Diff / Browser toggles are the same pair, offered
  at every rung for the selected workspace (see "Menu bar").

  All chrome comes from one shell: a fixed-height capsule with an explicit fill
  and a hairline border, plus a hover highlight and a pressed state past it —
  the fill steps further and the pill shrinks slightly, fill alone under Reduce
  Motion — that one button style reports to the shell whether the shell sits
  inside the button's label or around it. Glass was rejected because it renders
  nearly invisible on a chip embedding a borderless `Menu` (see
  [[glasseffect-nested-menu-invisible]]), and the fill is the same neutral step
  in both palettes — **no accent colour and no state tint anywhere**, so a
  Delete chip is not red (see [[title-bar-chip-chrome]]). The interior padding
  lives **inside** each control's label, never on the shell, so the whole pill
  is clickable rather than just the glyph ([[title-capsule-hit-area]]); `Label`s
  pin `.titleAndIcon` because the toolbar environment otherwise resolves them
  icon-only and drops the title ([[toolbar-label-style]]). The title capsule
  itself is chrome-less: it is not a control, so it takes the shared metrics
  without the pill — and every label in the row is pinned to one line, because a
  group with no line limit **wraps** mid-word once it is proposed less than its
  ideal width, and inside a fixed-height capsule a second line has nowhere to go
  ([[toolbar-group-truncation]]).

  **Every glyph-only chip measures exactly the same**, the `⋯` chip being the
  reference: one shared slot on `TitleCapsuleMetrics`, wide enough for the
  widest glyph any of them draws, so they are identical by construction rather
  than by symbols happening to agree. That is also what keeps the Merge chip
  from changing width the moment Option swaps it to Delete — `trash` and
  `arrow.triangle.merge` do not measure alike, and a chip that jumps under a
  stationary pointer breaks the same intent the shared-identity `Button` exists
  to protect.

  The **diff badge** renders whenever the diff lists at least one file — a
  rename-only or mode-only change shows `+0 −0` — and is hidden for a clean
  worktree, a non-Git workspace or a failed diff. Clicking it toggles the panel
  on the Diff tab — the same mutator as the segments, not an expand-only
  shortcut. Run Script and Editor are split buttons whose menu **only
  selects**; just the primary action runs or launches. The
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
  dwell and the absence of capsule chrome. Link routing is `README.md`'s to
  describe; the design constraints behind it are that ⌘ is the one modifier
  `NSTextView` does not already spend on a click, and that the routing is a pure
  decision so tests can pin it without a browser launching. See
  [[nstextview-link-cursor-and-selection]] and
  [[nstextblock-border-unreliable]].

  Sizing measures the message on the engine the live view will really be laid
  out with — **TextKit 1** when the rendered string holds a text block (a GFM
  table or a block quote), **TextKit 2** otherwise — because AppKit migrates
  such a view off TextKit 2 on a display pass and the two engines lay the same
  string out differently ([[textkit1-fallback-on-nstexttable]]). The engine is
  predicted rather than corrected for: a popover fixes its content size at the
  first layout pass, so height gained after that pass grows the scrolled
  document while the viewport stays where it is, leaving the tail of the
  message below the popover's bottom edge. The hosted view still reports what
  it laid out, and the frame takes the **maximum** of measurement and report as
  the safety net that keeps the scrolled document complete should the
  prediction ever be wrong: both are lower bounds and the failure modes are
  asymmetric — too tall costs a little invisible scroll slack, too short
  silently eats lines. The result is applied as a **cap, not a pinned height**,
  so the panel yields to a host with less room instead of hanging its tail
  somewhere unreachable ([[scrollview-viewport-vs-document]],
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
  so a slow `teardown` hook, a large worktree or a slow base resync never
  freezes the app. Offloading is safe because `WorktreeManager`'s entry
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
  rather than just the hook wait: an entry check alone guards nothing across the
  operation's `await`s, and both a menu action (a window-modal sheet does not
  disable the menu bar) and `casper workspace delete` can arrive mid-flight —
  which would strand a continuation and run two libgit2 writers at once. The
  control-channel path is deliberately silent: it reports back as JSON and gets
  no sheet.

  **What gets selected next** is a sibling in the same Space first — the Space's
  first workspace in display order (primary, then linked alphabetically) — and
  only failing that the first workspace of the first remaining Space. Removing
  a whole Space has no same-Space to prefer, so it always takes the second
  branch. The helper returns `nil` only when no candidate exists anywhere,
  upholding the invariant that selection is either `nil` or a live workspace and
  never dangles ([[workspace-selection-invariant]]). Landing on a sibling
  matters because closing one workspace of a repository is the middle of a piece
  of work, not the end of it: jumping to an unrelated Space would lose the
  user's place.

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
- **Software update** — `SoftwareUpdater` wraps **Sparkle**, and adds one group
  to the App menu: "Check for Updates…" after `.appInfo`. It stays inert unless
  the running bundle declares both an appcast feed URL and the EdDSA public key
  that authenticates it — Casper ships ad-hoc-signed, so that key, not
  code-signing continuity, is the whole of the trust chain — and the menu item
  is offered only when it does, a dead entry being worse than none. Only the
  release bundle carries the pair, so a dev build and an unbundled binary are
  quiet by construction. The operational side (the feed, the release job, key
  custody) belongs to `README.md` and [[sparkle-eddsa-key]].
