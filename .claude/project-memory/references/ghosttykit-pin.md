---
name: "GhosttyKit / libghostty pin"
description: "Exact pinned libghostty version, source, checksum, and vendored header for CasperGhostty"
type: reference
---

# GhosttyKit / libghostty pin

CasperGhostty links libghostty through the third-party binary Swift package
**`Lakr233/libghostty-spm`, pinned `exact: "1.2.8"`** in `Package.swift`. That
release ships `GhosttyKit.xcframework` built from upstream Ghostty **`v1.3.1`**
(commit `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`), plus Lakr233's own patches.

- binaryTarget asset:
  `https://github.com/Lakr233/libghostty-spm/releases/download/storage.1.2.8/GhosttyKit.xcframework.zip`
  checksum `eab8ecf086806acd6c0cfa198635c70e8b711c3a4d449bb0eb79b717b3960e24`
  (SwiftPM verifies this on resolve).
- Consume **only** the `GhosttyKit` product (the raw C-API re-export). Never
  `GhosttyTerminal`/`ShellCraftKit`/`GhosttyTheme` — those add an `MSDisplayLink`
  dependency. `MSDisplayLink` appears in `Package.resolved` (full manifest graph)
  but is **not linked** into Casper, so the five-external-deps policy holds
  (see [[dependency-policy]]).
- Required linker settings on the CasperGhostty target: `.linkedLibrary("c++")`
  and `.linkedFramework("Carbon", .when(platforms: [.macOS]))`.
- The API source of truth is the vendored header `Vendor/ghostty/ghostty.h`
  (sha256 `145d9e9f733c5c22615b80f17397b9640860448fd45394bc5fb1807fb4a33db7`,
  1196 lines), synced by Carvel `vendir` (`vendir.yml` / `vendir.lock.yml`,
  `make vendor`). It is copied out of the **extracted xcframework's own
  Headers directory**, so it mirrors the fork Casper actually links — not
  upstream Ghostty, whose struct layout differs. `make vendor` therefore
  requires a build to have downloaded and extracted the artifact first.
  Upstream `main` is doubly wrong as a reference: it also inserts
  `GHOSTTY_ACTION_SELECTION_CHANGED` mid-enum, renumbering every later action
  tag.

**Why:** the libghostty embedding API is unstable and changes between versions;
every `ghostty_*` symbol must be written against the exact pinned header, and the
binary is an opaque third-party artifact that must be trust-verified. Pinning
`exact:` (not `from:`) prevents a new release from silently shifting the ABI.

**How to access:** read `Vendor/ghostty/ghostty.h` for real signatures; re-sync
with `make vendor`. On any version bump: re-verify the xcframework checksum,
re-vendor the matching-tag header, diff the xcframework's bundled `ghostty.h`
against upstream, and update every affected `ghostty_*` call — all confined to
the `CasperGhostty` module. See [[dependency-policy]].
