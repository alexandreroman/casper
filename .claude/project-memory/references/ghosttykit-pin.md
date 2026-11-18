---
name: "GhosttyKit / libghostty pin"
description: "libghostty revision pin, its source, checksum and vendored header for CasperGhostty; why not the tag"
type: reference
---

# GhosttyKit / libghostty pin

CasperGhostty links libghostty through the third-party binary Swift package
**`Lakr233/libghostty-spm`, pinned by `revision:
"b9694b5014bcf783882328a04da37569422aebef"`** in `Package.swift` — the fork's
`2.2.2026111701` release. That release ships `GhosttyKit.xcframework` built
from upstream Ghostty commit **`5ebe501a63425b13d9952e8c54682c046386e5af`**,
395 commits past tag `v1.4.0` (`83fb956…`), plus Lakr233's own patches. No
fork build wraps `v1.4.0` exactly; Casper tracks the newest fork build rather
than an exact release wrap. Fork releases built on upstream `cf5519b`
(`2.2.2026111302` … `2.2.2026111601`) lack the resize fix below.

- binaryTarget asset: `https://github.com/Lakr233/libghostty-spm/releases/download/upstream.5ebe501a6342/GhosttyKit.xcframework.zip`
  checksum `219749b57f4677c8a6bc6b18f3a9684a92fb7a35a0509dd32e6caff4b9e78450`
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
  (sha256 `2b58e40253362e17b7d85c708f8695e97ddc5dd94eb5f6d8c31219744f50a849`,
  1363 lines), synced by Carvel `vendir` (`vendir.yml`, `make vendor`). It is
  copied out of the **extracted xcframework's own
  `Headers/libghostty/ghostty.h`** (next to its `module.modulemap`), so it
  mirrors the fork Casper actually links — not upstream Ghostty, whose struct
  layout differs (the fork adds `ghostty_surface_selection_viewport`, for
  one). `make vendor` therefore requires a build to have downloaded and
  extracted the artifact first.
- The header is nullability-audited (`#pragma clang assume_nonnull`, with
  `GHOSTTY_NULLABLE` on the exceptions), so Swift imports every unmarked
  pointer — the opaque handles, callback parameters, the clipboard `state` —
  as non-optional, and CasperGhostty's C callbacks must match those types
  exactly. Casper relies on that contract and carries no nil guards for
  pointers the header declares non-null.
- The fork's opt-in pixel smooth scrolling
  (`ghostty_surface_set_smooth_scroll`, patch `0022`) is off unless a host
  enables it; Casper does not call it, so scrolling follows upstream's
  whole-row behavior.
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
`String(cString:)` that then over-reads. See [[dependency-policy]]. A new
build must contain upstream Ghostty `8ad3f607f` (PR #15199, the fix for stale
prompt copies left by a column resize), or `SplitResizePromptE2ETests` fails.

## Why a revision and not the tag

The fork's tags are mutable (`immutable: false` on its releases), so a tag pin
can shift under Casper without any change on this side. The pinned `b9694b5…`
is the commit `refs/tags/2.2.2026111701` names, and it sits on the fork's
`main`.

An `exact:` version requirement also makes SwiftPM check the revision recorded
in `Package.resolved` against the commit the tag names on fetch: once the tag
moves, a cold cache fails at resolve. A revision pin has no such check to fail.

Verify with `git ls-remote https://github.com/Lakr233/libghostty-spm.git`
before concluding anything about which revision a ref names today.
