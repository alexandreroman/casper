---
name: "HighlightSwift resource bundle placement in app bundles"
description: "Bundle.module resolves only from the .app root or a machine-local build path, never Contents/Resources; a runtime mirror is required"
type: feedback
---

# HighlightSwift resource bundle placement in app bundles

HighlightSwift's SwiftPM-generated `Bundle.module` accessor resolves
`HighlightSwift_HighlightSwift.bundle` from exactly two candidates, in order:
`mainPath` = `Bundle.main.bundleURL.appendingPathComponent(
"HighlightSwift_HighlightSwift.bundle")` (for a macOS `.app`,
`Bundle.main.bundleURL` is the **`.app` root**, a sibling of `Contents/`), and a
hardcoded compile-time absolute `buildPath` pointing into the compiling
machine's `.build/…`. If neither exists it hits `Swift.fatalError` and the app
crashes (SIGTRAP) the first time diff-view syntax highlighting runs
(`HLJS.load()`). **`Bundle.main.resourceURL` / `Contents/Resources/` is never a
candidate** — the accessor does not use the standard multi-candidate template.

**Why:** on the compiling machine `buildPath` exists, so a local dev or release
build resolves the bundle even when the `.app` root copy is missing. This
**masks the real failure**: on any other machine (every downloaded release,
every CI-built `make dist` artifact) `buildPath` does not exist, so only the
`.app` root (`mainPath`) can satisfy the accessor. Content placed in
`Contents/Resources/` alone never resolves anywhere.

**How to apply:** the bundle must end up at the `.app` root at runtime, but it
cannot ship there — code signing seals only `Contents/`, and unsealed root
content breaks signing. So `Scripts/assemble-bundle.sh` — the one staging step
behind both `Casper.app` and `Casper-dev.app` — ships the bundle inside
`Contents/Resources/` as an ordinary sealed resource, and
`DiffHighlighter.resourceBundleReady` mirrors it from `Contents/Resources/` to
the `.app` root once, lazily, before the first highlight call. The mirror is
**load-bearing, not redundant** — never remove it or "simplify" the highlighter
to rely on `Contents/Resources`; a build that does so crashes for distributed
users while still passing on the compiling machine. The mirror is best-effort:
if the copy fails (read-only or translocated `.app`), the flag stays `false` and
`highlightedLines` falls back to neutral text instead of crashing.
