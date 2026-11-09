---
name: "GhosttyKit / libghostty pin"
description: "libghostty revision pin, its source, checksum and vendored header for CasperGhostty; why not the tag"
type: reference
---

# GhosttyKit / libghostty pin

CasperGhostty links libghostty through the third-party binary Swift package
**`Lakr233/libghostty-spm`, pinned by `revision:
"1d84cf66fe29abd1f24f10b88dcfc25882cf68ee"`** in `Package.swift` — the fork's
`2.2.2026110702` release. That release ships `GhosttyKit.xcframework` built
from upstream Ghostty commit **`042b16b6146ada29877dfeeea9f286889e4adeb1`**,
101 commits past tag `v1.4.0` (`83fb956…`), plus Lakr233's own patches. No
fork build wraps `v1.4.0` exactly; the latest build was chosen over waiting
for one.

- binaryTarget asset: `https://github.com/Lakr233/libghostty-spm/releases/download/upstream.042b16b6146a/GhosttyKit.xcframework.zip`
  checksum `1f5cd5cebcca5181ea5aaea008252a2b622ba1e94471601cf896ee125e9a5902`
  (SwiftPM verifies this on resolve).
- Consume **only** the `GhosttyKit` product: a Swift target that
  `@_exported import libghostty`, over the binary target `libghostty` whose C
  module is also named `libghostty`. Never `GhosttyTerminal`/`ShellCraftKit`/
  `GhosttyTheme` — those add a `DisplayLink` dependency. `Lakr233/DisplayLink`
  appears in `Package.resolved` (full manifest graph) but is **not linked**
  into Casper, so the five-external-deps policy holds (see
  [[dependency-policy]]).
- Required linker settings on the CasperGhostty target: `.linkedLibrary("c++")`.
- The API source of truth is the vendored header `Vendor/ghostty/ghostty.h`
  (sha256 `fe304f691877a6eeb99c821b27fa1b8506585f0316167a0cde298bceb5e33d48`,
  1321 lines), synced by Carvel `vendir` (`vendir.yml`, `make vendor`). It is
  copied out of the **extracted xcframework's own
  `Headers/libghostty/ghostty.h`** (next to its `module.modulemap`), so it
  mirrors the fork Casper actually links — not upstream Ghostty, whose struct
  layout differs (the fork adds `ghostty_surface_selection_viewport`, for
  one). `make vendor` therefore requires a build to have downloaded and
  extracted the artifact first.
- The header calls itself **"libghostty-internal"**: an API tailored to
  Ghostty's own macOS app and not designed for external embedders, with most
  functions undocumented. Read the matching upstream Zig source
  (`src/apprt/embedded.zig`, `src/Surface.zig`) at the wrapped commit for real
  semantics.
- `vendir.lock.yml` is gitignored and pins nothing: its `directory:` content
  type records no revision, digest or version. `vendir.yml` and
  `Package.resolved` carry the whole pin.

**Why:** the libghostty embedding API is unstable and changes between versions;
every `ghostty_*` symbol must be written against the exact pinned header, and
the binary is an opaque third-party artifact that must be trust-verified. A
revision pin names one immutable commit, so neither a new release nor a moved
tag can shift the ABI.

**How to access:** read `Vendor/ghostty/ghostty.h` for real signatures; re-sync
with `make vendor`. On any pin bump: pick the new revision from
`git ls-remote`, check it sits on the fork's `main` history, re-verify the
xcframework checksum, re-vendor the header from the new artifact, diff it
against the previous one, and update every affected `ghostty_*` call — all
confined to the `CasperGhostty` module. Mid-enum insertions renumber
`ghostty_action_tag_e`, so Casper matches action tags by symbolic name only.
The compiler does not catch every semantic change: a struct field that turns
a NUL-terminated buffer into a pointer-plus-length compiles unchanged around a
`String(cString:)` that then over-reads. See [[dependency-policy]].

## Why a revision and not the tag

The fork's tags are mutable (`immutable: false` on its releases), so a tag pin
can shift under Casper without any change on this side. The pinned `1d84cf6…`
is the commit `refs/tags/2.2.2026110702` names, and it sits on the fork's
`main`.

An `exact:` version requirement also makes SwiftPM check the revision recorded
in `Package.resolved` against the commit the tag names on fetch: once the tag
moves, a cold cache fails at resolve. A revision pin has no such check to fail.

Verify with `git ls-remote https://github.com/Lakr233/libghostty-spm.git`
before concluding anything about which revision a ref names today.
