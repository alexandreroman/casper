# Theme: Terminal Embedding (CasperGhostty)

**Module:** CasperGhostty · **Status:** ✅ one terminal end-to-end (see
`../status.md`) · **Code:** `Sources/CasperGhostty/`

The only module touching libghostty's unstable embedding API. In-process
surfaces and PTYs (same model as the Ghostty app).

## Design

- **`GhosttyRuntime`** — app lifecycle + C runtime callbacks + the wakeup→tick
  pump that drives libghostty's event loop.
- **`GhosttyAction`** — a pure decoder for libghostty action tags (fully tested).
- **`GhosttySurface`** (+ `GhosttySurfaceConfiguration`) — the surface handle and
  config marshaling.
- **`GhosttySurfaceView`** — the AppKit `NSView` host; **`GhosttySurfaceRepresentable`**
  bridges it into SwiftUI. **`GhosttyInput`** maps keyboard/scroll input.
- **`GhosttyDemo`** — a one-terminal window wired to `casper` GUI mode; installs
  the macOS main menu (`GhosttyMenu`) and routes `.quit`/`.closeWindow`/`.closeTab`.
- **`GhosttyMenu`** — the App/Edit/View/Window main menu; Edit/View items invoke
  libghostty binding actions (`copy_to_clipboard`, `paste_from_clipboard`,
  `select_all`, `increase_font_size`/`decrease_font_size`/`reset_font_size`) on the
  focused surface via the responder chain.
- **`GhosttyActionDispatcher`** — the extensible seam (`GhosttyActionHandler`) for
  libghostty app-level actions (`newTab`/`newSplit`/`newWindow`/`closeTab`/
  `closeWindow`); the default `LoggingActionHandler` logs unbuilt actions as no-ops.
- Rendering is **display-link driven**, so `GHOSTTY_ACTION_RENDER` needs no
  explicit `draw()` wiring.

### Keyboard & clipboard

- **Control / Option / plain keys** flow through `keyDown`; **Command combos**
  through `performKeyEquivalent` (gated to `.command`), which forwards them into
  libghostty's keybinding engine. Control-char encoding relies on
  `unshifted_codepoint` being set on the bare key event — see
  [[ghostty-key-encoding]].
- **Clipboard** — the libghostty `read`/`write`/`confirm` callbacks are backed by
  `NSPasteboard`, resolved to the surface via the per-surface `userdata` (the view
  pointer); paste completes through `ghostty_surface_complete_clipboard_request` —
  see [[ghostty-clipboard-callbacks]].
- **`macos-option-as-alt`** is wired via `ghostty_surface_key_translation_mods`;
  the observable effect is inert in the current pinned binary (revisit on pin bump)
  — see [[ghostty-option-as-alt]].

Embedding is pinned — every `ghostty_*` call is written against the exact vendored
header. See [[ghosttykit-pin]]. Correct glyph size requires syncing the Metal
layer's `contentsScale` to the window backing scale — see
[[ghostty-layer-contents-scale]].

## Remaining (for CasperUI)

- **Splits/tabs layout composition — ✅ done (CasperUI UI-3), now tmux-style.**
  The decoded `newSplit`/`newTab`/`closeTab` actions are composed into a recursive
  `LayoutNode` tree by CasperUI's `LayoutActionHandler` (installed on
  `GhosttyRuntime.actionHandler`). **Tabs are gone**: `LayoutNode` is now
  `split | leaf`, rendered as native split views only (no tab bar); `newTab` maps
  to a right split. `close_surface_cb` is wired (Ctrl-D / `exit` closes the pane
  via `GhosttySurfaceView.onClose`). See `../status.md` → "Surface layout —
  tmux-style panes".
- `flagsChanged` press/release semantics and scroll precision/momentum.
- **Clipboard paste confirmation** — `write_clipboard_cb`'s `confirm` flag is not
  gated (v1 auto-confirm); honor it once a confirmation UI exists so untrusted
  OSC-52 output can't silently overwrite the clipboard.
- **Real-keypress verification** — `performKeyEquivalent`, the menu ⌘-shortcuts,
  and ⌘W/close depend on real OS key events; the debug channel bypasses them, so
  they are confirmed by structure + a live keypress, not by automated e2e.
