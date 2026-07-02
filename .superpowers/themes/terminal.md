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
- **`GhosttyDemo`** — a one-terminal window wired to `casper` GUI mode.
- Rendering is **display-link driven**, so `GHOSTTY_ACTION_RENDER` needs no
  explicit `draw()` wiring.

Embedding is pinned — every `ghostty_*` call is written against the exact vendored
header. See [[ghosttykit-pin]]. Correct glyph size requires syncing the Metal
layer's `contentsScale` to the window backing scale — see
[[ghostty-layer-contents-scale]].

## Remaining (for CasperUI)

- **Splits/tabs layout composition** — the split/tab actions are decoded but not
  yet acted on; composing them into the layout tree belongs to the app.
- Clipboard copy/paste fidelity (callbacks are stubs).
- `flagsChanged` press/release semantics and scroll precision/momentum.
