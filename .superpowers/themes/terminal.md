# Theme: Terminal Embedding (CasperGhostty)

**Module:** CasperGhostty · **Status:** ✅ one terminal end-to-end (see
`../status.md`) · **Code:** `Sources/CasperGhostty/`

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
  keyboard/scroll input.
- **`PersistentNSViewHost`** — the SwiftUI bridge. It re-parents an *existing*
  `NSView` into a fresh container on each rebuild instead of creating a new one,
  so a surface's PTY survives layout restructuring; ownership is driven by
  window membership (see [[persistent-nsview-host-sharing]]).
- **`GhosttyDefaultConfig`** — the baked-in default terminal theme, loaded
  before the user's own Ghostty config so user settings still win (see
  [[ghostty-config-dir-bundle-id]]).
- **`GhosttyActionDispatcher`** — the extensible seam (`GhosttyActionHandler`)
  for libghostty app-level actions (`newTab`/`newSplit`/`newWindow`/`closeTab`/
  `closeWindow`); the default `LoggingActionHandler` logs unbuilt actions as
  no-ops.
- Rendering is **display-link driven**, so `GHOSTTY_ACTION_RENDER` needs no
  explicit `draw()` wiring.

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
- **Main menu** — the App/Edit/View/Window menu bar is SwiftUI `.commands` in
  CasperUI (`MenuCommands.swift`), not an AppKit menu built here; its Edit/View
  items invoke libghostty binding actions (`copy_to_clipboard`,
  `paste_from_clipboard`, `select_all`,
  `increase_font_size`/`decrease_font_size`/`reset_font_size`) on the focused
  surface through the responder chain. See
  [[swiftui-mainmenu-miniaturize-resync]].
- **`macos-option-as-alt`** is wired via `ghostty_surface_key_translation_mods`;
  the observable effect is inert in the current pinned binary (revisit on pin
  bump) — see [[ghostty-option-as-alt]].

Embedding is pinned — every `ghostty_*` call is written against the exact
vendored header. See [[ghosttykit-pin]]. Correct glyph size requires syncing the
Metal layer's `contentsScale` to the window backing scale — see
[[ghostty-layer-contents-scale]].

## Remaining (for CasperUI)

- **Splits/tabs layout composition — ✅ done (CasperUI UI-3), now tmux-style.**
  The decoded `newSplit`/`newTab`/`closeTab` actions are composed into a
  recursive `LayoutNode` tree by CasperUI's `LayoutActionHandler` (installed on
  `GhosttyRuntime.actionHandler`). **Tabs are gone**: `LayoutNode` is now
  `split | leaf`, rendered as native split views only (no tab bar); `newTab`
  maps to a right split. `close_surface_cb` is wired (Ctrl-D / `exit` closes the
  pane via `GhosttySurfaceView.onClose`). See `../status.md` → "Surface layout —
  tmux-style panes".
- **`flagsChanged` press/release semantics — ✅ done.** A modifier transition is
  reported as a press while the modifier is still held and a release once it is
  let go, mapped from the physical key code (Ghostty is the reference).
- **Scroll precision/momentum — ✅ done.** `scrollWheel` packs the precision bit
  and the momentum phase into `ghostty_input_scroll_mods_t` — see
  [[ghostty-scroll-mods-layout]].
- **Clipboard write confirmation — ✅ done.** `write_clipboard_cb`'s `confirm`
  flag is honored: `GhosttyClipboardWrite.apply(_:confirm:to:)` routes an
  untrusted write through `approveUntrusted`, an `NSAlert` previewing the
  content whose "Allow" button deliberately carries **no** Return key
  equivalent, so a stray Return can never grant clipboard access. Nothing
  remains for CasperUI here.
- **Real-keypress verification** — `performKeyEquivalent`, the menu ⌘-shortcuts,
  and ⌘W/close depend on real OS key events; the debug channel bypasses them, so
  they are confirmed by structure + a live keypress, not by automated e2e.
