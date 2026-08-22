# Per-Terminal Font Size Persistence — Design

**Date:** 2026-07-08 **Status:** Shipped **Scope:** Remember each terminal
surface's current font size (as adjusted via Cmd+/Cmd-/Cmd0) and restore it the
next time Casper launches, per terminal.

## Problem

`GhosttySurfaceConfiguration.fontSize`
(`GhosttySurfaceConfiguration.swift`) is only ever used at *surface
creation* time, defaulting to `0` (libghostty's own default). Runtime font-size
changes go through
`GhosttySurfaceView.increaseFontSize`/`decreaseFontSize`/`resetFontSize`
(`GhosttySurfaceView.swift`), which forward to
`surface?.bindingAction("increase_font_size:1")` etc. — entirely internal to
libghostty. Swift never learns the resulting size, so it's lost on quit and
every terminal reopens at the default size.

libghostty exposes no getter and no change callback for a surface's live font
size. It does expose `ghostty_surface_inherited_config(ghostty_surface_t,
ghostty_surface_context_e) -> ghostty_surface_config_s` (`ghostty.h:1095`),
unused today, which returns a surface's *live* config (including `font_size`,
`ghostty.h:461`) — this is presumably how libghostty makes a new split/tab
inherit the parent's runtime-adjusted font size. This is the only available read
path for the current size.

`Session`/`SessionStore` already round-trips the full layout tree (`Space` →
`Workspace` → `LayoutNode` → `Surface`) to `session.json` on every discrete
model mutation via `AppModel.persist()` (called
directly or via the debounced `scheduleSave()`/`flushPendingSave()`,
`AppModel.scheduleSave()`), so the storage mechanism already exists — only the
font size value itself is missing from the model.

## Goals

- Each terminal (`Surface` with `.terminal` kind) remembers its own font size,
  independent of other terminals in the same or other workspaces.
- Changing a terminal's font size (increase/decrease/reset) persists that change
  without requiring an unrelated action to trigger a save first — reuse the
  existing debounced-save pattern (same as inspector-width drag).
- Restoring a session (relaunch) re-applies each terminal's last known font size
  when its surface is (lazily) created.
- Old `session.json` files without a font size on a terminal load unaffected
  (default to libghostty's own default, same as today).

## Non-Goals

- No new global/default font-size *preference* (e.g. `AppStorage`) — none exists
  today (confirmed: no `AppStorage`/`UserDefaults` usage anywhere in
  `Sources/**`) and none is requested.
- No periodic/idle autosave timer. `AppModel` already saves purely on mutation
  events plus quit — this feature reuses that, it doesn't add a new save trigger
  mechanism.
- No font-size *sharing* across splits/tabs beyond whatever libghostty itself
  already does when a new split inherits its parent's config at creation time
  (unchanged, out of scope).

## Design

### Data model — `Models.swift`

Add a top-level `fontSize: Float?` field to `Surface` (not to `Kind`'s
associated values — keeping this a flat field on `Surface` matches the
established migration pattern already used for `InspectorState.width`,
`Workspace.inspector`, and `Space.isCollapsed` in this same file, all of which
hand-roll `Codable` to default a new field for legacy files). `nil` means "not
customized — use libghostty's default"; only meaningful for `.terminal`
surfaces, ignored for `.browser`.

```swift
public struct Surface: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: Codable, Equatable, Sendable { /* unchanged */ }

    public var id: UUID
    public var kind: Kind
    public var fontSize: Float?

    public init(id: UUID = UUID(), kind: Kind, fontSize: Float? = nil) {
        self.id = id
        self.kind = kind
        self.fontSize = fontSize
    }

    private enum CodingKeys: String, CodingKey { case id, kind, fontSize }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.kind = try c.decode(Kind.self, forKey: .kind)
        self.fontSize = try c.decodeIfPresent(Float.self, forKey: .fontSize)
    }
    // encode(to:) stays synthesized-equivalent: encode all three fields.
}
```

`.terminal(cwd:, command:)` static helper (`Surface.terminal(cwd:command:)`,
`CasperCore/Models.swift`) is unaffected — `fontSize` defaults to `nil` there.

### Capture (write path) — `GhosttyKit` layer + `AppModel`

`GhosttySurface` (`GhosttySurface.swift`) gains a method mirroring its existing
thin wrappers (`geometry()`, `readText(scrollback:)`,
`GhosttySurface.swift`):

```swift
/// The surface's current live font size, read via libghostty's
/// inherited-config mechanism (the same path it uses to propagate the
/// current, possibly runtime-adjusted, font size to a new child split).
func currentFontSize() -> Float {
    ghostty_surface_inherited_config(surface, GHOSTTY_SURFACE_CONTEXT_WINDOW).font_size
}
```

`GhosttySurfaceView` gains an `onFontSizeChange: (UUID, Float) -> Void` closure,
stored alongside the existing `onClose` (constructor-injected the same way).
`increaseFontSize`/`decreaseFontSize`/`resetFontSize`
(`GhosttySurfaceView.swift`) each read back the size immediately after
forwarding the binding action and invoke the closure if it changed:

```swift
@objc func increaseFontSize(_ sender: Any?) {
    surface?.bindingAction("increase_font_size:1")
    reportFontSizeIfChanged()
}
// decreaseFontSize / resetFontSize follow the same shape

private func reportFontSizeIfChanged() {
    guard let surface, let surfaceID else { return }
    let size = surface.currentFontSize()
    if size != lastReportedFontSize {
        lastReportedFontSize = size
        onFontSizeChange(surfaceID, size)
    }
}
```

`AppModel` wires this closure at the single surface-creation chokepoint
(`surfaceView(for:in:)` / `surfaceConfiguration(for:terminal:)`,
`AppModel`) to a new method that locates the `Surface`
by id in its owning workspace's `LayoutNode` tree, sets `.fontSize`, and calls
`AppModel.scheduleSave()` (the existing 0.5s-debounced save —
same mechanism already used for inspector-width drag). No change to `persist()`
itself: it already serializes `spaces` wholesale, so the mutated `fontSize`
rides along automatically.

### Restore (read path) — `AppModel.surfaceView(for:in:)`

`surfaceConfiguration(for workspace:terminal:)` passes `terminal.fontSize ?? 0`
into `GhosttySurfaceConfiguration.fontSize` instead of the current hardcoded
`0`. Since this is the *only* place a `Surface` becomes a
`GhosttySurfaceConfiguration` — used identically whether the `Surface` came from
a restored `session.json` or was just-created by the user — restore and
fresh-terminal creation both fall out of this one change with no separate
"restore path" to maintain.

### Ordering note (already safe, no change needed)

`AppModel.discardSurfaceViews(_:)` (which frees the live
`ghostty_surface_t` via `GhosttySurfaceView` deallocation) runs *before*
`persist()` on every close path (`applyCloseSurface`, `removeWorkspace`,
`removeSpace`). That's fine here: the surface being closed is also removed from
`spaces` in that same operation, so its font size no longer needs reading at
that point. Every *other* surface still open in that workspace or elsewhere
remains in `surfaceViews` and reachable — but reading isn't needed there either,
since capture already happened at change-time (see above), not at persist-time.
`persist()` needs no libghostty calls at all.

## Risk / Spike

`ghostty_surface_inherited_config`'s behavior when reading back a
runtime-adjusted font size (as opposed to its documented purpose of building a
config for a *new child* surface) is inferred from the header/naming, not
confirmed by any existing usage in this codebase or written test. **First
implementation step:** a manual spike — call `currentFontSize()` after changing
a terminal's font size via Cmd+, log the value, and confirm it reflects the
adjustment — before building the rest of the feature on top of it. If it does
*not* reflect live changes (e.g. it only echoes the surface's original
creation-time config), this design's capture mechanism does not work and needs
revisiting — see Alternatives below.

## Alternatives considered

- **Track font size purely in Swift, bypass libghostty's own
  increase/decrease/reset actions**: instead of forwarding to libghostty's
  `bindingAction`, compute the new size in Swift (base size, fixed step) and
  push it via `ghostty_surface_update_config`. Rejected for now — no `set` API
  for a single surface's font size was found (`update_config` takes a full
  `ghostty_config_t`, a heavier mechanism intended for reloading the whole user
  config, not a targeted single-field override), and it would duplicate
  libghostty's own step/min/max font-size logic in Swift. Revisit only if the
  spike above shows `ghostty_surface_inherited_config` doesn't reflect live
  changes.

## Testing

- `SurfaceTests`/`ModelsTests` (CasperCoreTests): `Surface` round-trips
  `fontSize` through `Codable`; decoding a `session.json` fixture without a
  `fontSize` key yields `nil`.
- `GhosttySurfaceView`/`AppModel` level: verify `onFontSizeChange` fires with
  the value read from `currentFontSize()` after each of increase/decrease/reset,
  and that `AppModel`'s handler updates the correct `Surface` in the layout tree
  and triggers a debounced save.
- Manual verification via `make dev` (per the `test-toolchain` / `app-sessions`
  memory notes — always under `--session dev`): open a terminal, Cmd+ a few
  times, quit, relaunch, confirm the terminal reopens at the enlarged size while
  a different, untouched terminal in another workspace reopens at the default
  size.
