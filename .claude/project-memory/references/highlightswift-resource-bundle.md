---
name: "HighlightSwift resource bundle placement in app bundles"
description: "HighlightSwift_HighlightSwift.bundle must sit at the .app root, copied after all codesign steps"
type: feedback
---

# HighlightSwift resource bundle placement in app bundles

HighlightSwift's SwiftPM-generated `Bundle.module` accessor resolves its
resource bundle via `Bundle.main.bundleURL.appendingPathComponent(
"HighlightSwift_HighlightSwift.bundle")`. For a macOS `.app`,
`Bundle.main.bundleURL` is the `.app` directory itself, so the bundle must be
copied to the **app root** (sibling of `Contents/`), NOT into
`Contents/Resources/`. Both `Makefile` (`Casper-dev.app`) and
`Scripts/bundle-app.sh` (release `Casper.app`) do this copy.

**Why:** without it, both the generated `mainPath` and the hardcoded `buildPath`
candidates fail `Bundle(path:)` on any machine other than the compiling one,
`Bundle.module` hits `Swift.fatalError`, and the app crashes (SIGTRAP) the first
time diff-view syntax highlighting runs (`HLJS.load()`). Placing it in
`Contents/Resources/` does not help — that path is never checked by the accessor.

**How to apply:** always copy `HighlightSwift_HighlightSwift.bundle`
(with `cp -R`, it is a directory) to the app root **after every codesign step**,
never before. A code signature seals only `Contents/`, so content at the bundle
root is unsealed; codesigning while it is present fails with "unsealed contents
present in the bundle root". In the Makefile the copy goes after the
`codesign … $(DEV_APP)` block; in `bundle-app.sh` it goes after both dylibbundler
(which internally codesigns the main executable — and codesigning a Mach-O that
is a bundle's main executable makes codesign walk the whole bundle) and the final
explicit `codesign` of the binary. Copying after signing keeps the signature
valid (the root sibling is legitimately outside the seal), and the app still
launches under local ad-hoc/dev signing. The bundle is a plain resource directory
(no Info.plist, not a Mach-O), so `bundle-app.sh`'s relocatability self-check
ignores it.
