---
name: "libgit2 linker warning is benign, left unsuppressed"
description: "The macOS-version linker warning from Homebrew's libgit2 dylib is intentionally not suppressed"
type: reference
---

# libgit2 linker warning is benign, left unsuppressed

Every build (`make dev`/`make build`/`make release`) emits:
`ld: warning: building for macOS-15.0, but linking with dylib
'/opt/homebrew/opt/libgit2/lib/libgit2.1.9.dylib' which was built for newer
version 26.0`. This is expected and intentionally left as-is — do not try to
"fix" it.

**Why:** The deployment target is macOS 15 (a hard constraint), but the Homebrew
`libgit2` bottle is built against the host SDK (`LC_BUILD_VERSION minos 26.0`).
The mismatch is ABI-compatible and harmless. No targeted linker flag exists for
this specific message (ld 1267 only offers `-no_warn_inits`,
`-no_warn_duplicate_libraries`, `-no_warn_reduced_section_align`,
`-no_warn_unused_dylibs` — none match); the only suppression is `-w`, which hides
ALL linker warnings and was rejected as too broad. Rebuilding/vendoring libgit2
for macOS 15 was rejected as too heavy versus the current `.brew(["libgit2"])`
setup.

**How to access:** Confirm the cause with
`otool -l /opt/homebrew/opt/libgit2/lib/libgit2.*.dylib | grep -A4 LC_BUILD_VERSION`.
See the linking setup in [Package.swift](../../Package.swift) (`Clibgit2`
systemLibrary) and the [libgit2 Swift interop](libgit2-swift-interop.md) note.
