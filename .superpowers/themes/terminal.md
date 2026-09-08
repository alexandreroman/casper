# Theme: Terminal Embedding (CasperGhostty)

**Module:** CasperGhostty · **Status:** ✅ built (see `../status.md`) ·
**Code:** `Sources/CasperGhostty/`

The only module touching libghostty's unstable embedding API. In-process
surfaces and PTYs (same model as the Ghostty app).

## Design

- **`GhosttyRuntime`** — app lifecycle + C runtime callbacks + the wakeup→tick
  pump that drives libghostty's event loop.
- **`GhosttyAction`** — a pure decoder for libghostty action tags (fully
  tested).
- **`GhosttySurface`** (+ `GhosttySurfaceConfiguration`) — the surface handle
  and config marshaling.
- **`GhosttySurfaceView`** — the AppKit `NSView` host; **`GhosttyInput`** maps
  keyboard input only. Pointer input (`scrollWheel` and the mouse events) is
  mapped by the view itself.
- **`PersistentNSViewHost`** — the SwiftUI bridge. It re-parents an *existing*
  `NSView` into a fresh container on each rebuild instead of creating a new one,
  so a surface's PTY survives layout restructuring; ownership is driven by
  window membership (see [[persistent-nsview-host-sharing]]).
- **`GhosttyDefaultConfig`** — the baked-in default terminal theme, loaded
  before the user's own Ghostty config so user settings still win (see
  [[ghostty-config-dir-bundle-id]]).
- **`GhosttyActionDispatcher.swift`** — the extensible seam: the
  `GhosttyActionHandler` protocol plus the default `LoggingActionHandler`, which
  claims nothing and logs whatever it is handed as an explicit no-op. (There is
  no type named `GhosttyActionDispatcher`; the file is named for the role.)
  `GhosttyRuntime.handleAction` offers the seam exactly five app-level actions —
  `newSplit`, `newTab`, `newWindow`, `closeTab`, `closeWindow` — and falls
  through to `onAction` for anything a handler leaves unclaimed. `openURL` (a
  cmd+clicked link) and `quit` never reach the seam at all: they are handled
  straight off `onAction` in CasperUI's `AppDelegate`, alongside the
  `closeWindow` fallback.
- **Rendering is libghostty's**, not Casper's: it owns the Metal layer and
  drives it from its own render thread. `GHOSTTY_ACTION_RENDER` is decoded like
  any other action but needs no `draw()` wiring on the AppKit side — the view's
  job is to keep the layer's `contentsScale` and occlusion state correct, not to
  schedule frames.

### Keyboard & clipboard

- **Control / Option / plain keys** flow through `keyDown`; **Command combos**
  through `performKeyEquivalent` (gated to `.command`), which forwards them into
  libghostty's keybinding engine. Control-char encoding relies on
  `unshifted_codepoint` being set on the bare key event — see
  [[ghostty-key-encoding]].
- **Clipboard** — the libghostty `read`/`write`/`confirm` callbacks are backed
  by `NSPasteboard`, resolved to the surface via the per-surface `userdata` (the
  view pointer); paste completes through
  `ghostty_surface_complete_clipboard_request` — see
  [[ghostty-clipboard-callbacks]].
- **Main menu** — the App/Space/Edit/View/Window menu bar is SwiftUI `.commands`
  in CasperUI (`MenuCommands.swift`), not an AppKit menu built here. Its Edit
  group's Copy/Paste/Select All reach the focused surface through the responder
  chain, where `GhosttySurfaceView` turns them into libghostty binding actions
  (`copy_to_clipboard`, `paste_from_clipboard`, `select_all`). The same group
  also holds two items that are **workspace**-scoped rather than
  surface-scoped — Copy Workspace Path and Copy Branch Name — which act on the
  selected workspace and never touch a surface. The View group holds the four
  pane splits and nothing else: font size is changed by libghostty's own
  keybindings inside the surface and reported back to the model through
  `onFontSizeChange`, so no menu item drives it. See
  [[swiftui-mainmenu-miniaturize-resync]].
- **`macos-option-as-alt`** is wired via `ghostty_surface_key_translation_mods`;
  the observable effect is inert in the current pinned binary (revisit on pin
  bump) — see [[ghostty-option-as-alt]].

Embedding is pinned — every `ghostty_*` call is written against the exact
vendored header. See [[ghosttykit-pin]]. Correct glyph size requires syncing the
Metal layer's `contentsScale` to the window backing scale — see
[[ghostty-layer-contents-scale]].

## Composition by CasperUI

CasperUI's `LayoutActionHandler`, installed on `GhosttyRuntime.actionHandler`,
claims four of the seam's five actions. Three of them — `newSplit`, `newTab`,
`closeTab` — are composed into a recursive `LayoutNode` tree. The fourth,
`newWindow`, has no layout meaning in a single-window app, so it is remapped
onto the nearest honest equivalent and opens the New Space panel; it is the one
case deferred to the next main-loop turn rather than run inline, because its
modal `NSSavePanel` must not hold libghostty's tick open. **Tabs are gone**:
`LayoutNode` is `split | leaf`, rendered by CasperUI's own `SplitContainerView`,
and `newTab` maps to a right split. `close_surface_cb` is wired, so Ctrl-D or
`exit` closes the pane via `GhosttySurfaceView.onClose`. See `app-ui.md`
§ Design → "Layout composition".

## Standing caveat

**Real-keypress verification.** `performKeyEquivalent`, the menu ⌘-shortcuts and
⌘W/close depend on real OS key events, which the debug channel bypasses. They
are confirmed by structure plus a live keypress, never by automated e2e.
