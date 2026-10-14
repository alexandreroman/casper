---
name: "GhosttyKit / libghostty pin"
description: "libghostty revision pin, its source, checksum and vendored header for CasperGhostty; why not the tag"
type: reference
---

# GhosttyKit / libghostty pin

CasperGhostty links libghostty through the third-party binary Swift package
**`Lakr233/libghostty-spm`, pinned by `revision:
"839f269bcd5193d03293cb6717ed2582dde265ef"`** in `Package.swift` — the fork's
`1.2.8` release. That release ships `GhosttyKit.xcframework` built from
upstream Ghostty **`v1.3.1`** (commit
`332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`), plus Lakr233's own patches.

- binaryTarget asset: `https://github.com/Lakr233/libghostty-spm/releases/download/storage.1.2.8/GhosttyKit.xcframework.zip`
  checksum `eab8ecf086806acd6c0cfa198635c70e8b711c3a4d449bb0eb79b717b3960e24`
  (SwiftPM verifies this on resolve).
- Consume **only** the `GhosttyKit` product (the raw C-API re-export). Never
  `GhosttyTerminal`/`ShellCraftKit`/`GhosttyTheme` — those add an
  `MSDisplayLink` dependency. `MSDisplayLink` appears in `Package.resolved`
  (full manifest graph) but is **not linked** into Casper, so the
  five-external-deps policy holds (see [[dependency-policy]]).
- Required linker settings on the CasperGhostty target: `.linkedLibrary("c++")`.
- The API source of truth is the vendored header `Vendor/ghostty/ghostty.h`
  (sha256 `145d9e9f733c5c22615b80f17397b9640860448fd45394bc5fb1807fb4a33db7`,
  1196 lines), synced by Carvel `vendir` (`vendir.yml`, `make vendor`). It is
  copied out of the **extracted xcframework's own Headers directory**, so it
  mirrors the fork Casper actually links — not upstream Ghostty, whose struct
  layout differs. `make vendor` therefore requires a build to have downloaded
  and extracted the artifact first. Upstream `main` is doubly wrong as a
  reference: it also inserts `GHOSTTY_ACTION_SELECTION_CHANGED` mid-enum,
  renumbering every later action tag.
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
`git ls-remote`, re-verify the xcframework checksum, re-vendor the header from
the new artifact, diff it against the previous one, and update every affected
`ghostty_*` call — all confined to the `CasperGhostty` module. See
[[dependency-policy]].

## Why a revision and not the `1.2.8` tag

The fork's tags are mutable: `refs/tags/1.2.8` names
`2ef85df0292dc864a857d30963b943e5d5b8dc87`, a rewritten copy of the release
commit, while the checksum and the vendored header above were taken from
`839f269…`. An `exact: "1.2.8"` requirement makes SwiftPM check the recorded
revision against the tag it fetches, so a cold cache fails at resolve.

`2ef85df…` and `839f269…` carry the same tree (`32723787e660…`), so they name
the same binary asset and checksum. `839f269…` sits on no upstream branch or
tag; only GitHub's `refs/pull/*/head` refs reach it. SwiftPM's repository
mirror fetches `+refs/*:refs/*`, so a fresh clone with an empty cache still
resolves it. If those refs ever stop reaching it, `2ef85df…` (on `main`) is a
drop-in revision with identical contents.

Verify with `git ls-remote https://github.com/Lakr233/libghostty-spm.git`
before concluding anything about which revision a ref names today.
