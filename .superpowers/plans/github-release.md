# GitHub Release Workflow with Downloadable `.app` — Design

**Date:** 2026-07-05
**Status:** Approved (pending written-spec review)
**Scope:** A GitHub Actions workflow that publishes a downloadable, self-contained
`Casper.app` on each version tag — **without** code signing or notarization — and
lays the groundwork so a Sparkle-based auto-update mechanism can plug in later
without reworking the release pipeline.

## Problem

`swift build` already compiles the project in CI (`.github/workflows/ci.yml`,
`macos-15`). But that produces a bare Mach-O executable with a **hard dynamic
dependency on Homebrew's libgit2**:

```
$ otool -L .build/.../release/casper
    /opt/homebrew/opt/libgit2/lib/libgit2.1.9.dylib
```

which in turn pulls `llhttp` and `libssh2` (and their transitive dylibs). On any
Mac without Homebrew + that exact libgit2 at that path, the app fails to launch
with a `dyld: Library not loaded` error. GhosttyKit, by contrast, is a **static**
library (`libghostty.a`) and links straight into the binary — nothing to ship.

So there is nothing missing to *compile*; what is missing is a **portable,
downloadable artifact** and the release automation to publish it.

## Goals

- Publish a downloadable `Casper.app` (inside a `.zip`) as a GitHub Release
  asset on every `v*` tag.
- The app must launch on a clean Mac (no Homebrew) — bundle and re-path the
  libgit2 dylib chain.
- Deterministic, reproducible build (pinned Xcode).
- Emit metadata and use an artifact layout that a future **Sparkle** auto-update
  mechanism can consume without changing the pipeline.

## Non-Goals (deliberate)

- No code signing, no notarization (accept Gatekeeper prompts).
- No app icon, no DMG, no universal binary (project is **arm64-only**).
- No implementation of the auto-update engine itself — only forward-compatible
  scaffolding.
- No change to the existing `ci.yml` build/test workflow.

## Why `.app` (not a bare executable)

- A GUI app users download and double-click expects a bundle (name, future icon,
  `/Applications` drop target).
- **It fixes a real defect:** `UNUserNotificationCenter` requires a valid bundle
  identifier. The current bare executable cannot register for notifications; a
  `.app` with an `Info.plist` `CFBundleIdentifier` unblocks that.
- Sparkle updates a `.app` delivered as a top-level `.zip` — the same artifact we
  produce.

## Components

### 1. Packaging assets (committed, reusable locally)

**`Packaging/Info.plist`** — template with a `__SHORT_VERSION__` /
`__BUNDLE_VERSION__` placeholder pair. Keys:

| Key | Value |
| --- | --- |
| `CFBundleName` | `Casper` |
| `CFBundleExecutable` | `casper` |
| `CFBundleIdentifier` | `com.alexandreroman.casper` |
| `CFBundlePackageType` | `APPL` |
| `CFBundleShortVersionString` | `__SHORT_VERSION__` (marketing, e.g. `0.1.0`) |
| `CFBundleVersion` | `__BUNDLE_VERSION__` (monotonic integer, see below) |
| `LSMinimumSystemVersion` | `15.0` |
| `NSHighResolutionCapable` | `true` |
| `LSApplicationCategoryType` | `public.app-category.developer-tools` |
| `SUFeedURL` *(reserved)* | `https://github.com/alexandreroman/casper/releases/latest/download/appcast.xml` |
| `SUPublicEDKey` *(reserved, TODO)* | empty — filled when the EdDSA keypair exists |

No `LSUIElement` — the app uses `setActivationPolicy(.regular)` and is a normal
foreground app. The `SU*` keys are inert until Sparkle is integrated but document
the wiring.

**`Scripts/bundle-app.sh <short-version> <bundle-version>`** — assembles the
bundle:

1. `Casper.app/Contents/MacOS/casper` ← the `swift build -c release` binary.
2. `Casper.app/Contents/Info.plist` ← template with versions substituted.
3. `dylibbundler -cd -b -x Casper.app/Contents/MacOS/casper -d
   Casper.app/Contents/Frameworks -p @executable_path/../Frameworks` — copies
   every non-system dylib (libgit2, llhttp, libssh2, and transitive deps) into
   `Contents/Frameworks/` and rewrites all `install_name`s to `@rpath` /
   `@executable_path/../Frameworks`.
4. **Self-check (hard fail):** `otool -L` on the bundled binary **and** each
   bundled dylib; if any `LC_LOAD_DYLIB` still points at `/opt/homebrew` or other
   non-system, non-`@rpath` path, exit non-zero. This is the guarantee that the
   artifact runs on a clean Mac — the closest proxy to testing on one.

**`Makefile`** — two new targets:

- `bundle` — runs `make release` then `Scripts/bundle-app.sh` → `Casper.app`.
- `dist` — runs `bundle`, then zips to `dist/Casper-<version>-arm64.zip` and
  writes `dist/Casper-<version>-arm64.zip.sha256`.

Both are usable locally so the release is reproducible off-CI.

### 2. Release workflow `.github/workflows/release.yml`

- **Trigger:** `push` on tags matching `v*` **publishes a release**; a
  `workflow_dispatch` with a `version` input is a **true dry-run** — it builds
  and packages, then uploads the artifacts to the workflow run (via
  `actions/upload-artifact`) **without** creating a release or a git tag.
- **`permissions: contents: write`** — required to create a release.
- **Runner:** `macos-15` (arm64), consistent with `ci.yml`.
- **Steps:**
  1. `actions/checkout@v4` with `fetch-depth: 0` (needed for the monotonic
     `git rev-list --count HEAD`).
  2. `maxim-lobanov/setup-xcode@v1` **pinned** to an explicit version (`16.2`)
     — removes the `latest-stable` non-determinism flagged as a risk.
  3. `brew install libgit2 pkgconf dylibbundler`.
  4. Derive `SHORT_VERSION` (tag without the `v`) and `BUNDLE_VERSION`
     (`git rev-list --count HEAD`); **validate** `SHORT_VERSION` against
     `^[0-9A-Za-z.+-]+$` and reject anything else (blocks script/XML injection
     from the free-text dispatch input).
  5. `make dist` (which runs `swift build -c release` → `bundle-app.sh`). All
     interpolated values (`github.ref_name`, `inputs.version`,
     `github.repository`) flow through `env:` vars, never inlined into `run:`
     script text.
  6. Regenerate `appcast.xml` (see §3) and stage it alongside the zip.
  7. **Publish** (only on `push`): idempotent — `gh release view "$TAG"` then
     either `gh release upload "$TAG" … --clobber` (release exists) or
     `gh release create "$TAG" dist/Casper-*.zip dist/*.sha256 appcast.xml
     --title … --notes-file Packaging/release-notes.md`. Uses the preinstalled
     `gh` CLI (no third-party action); `GH_TOKEN` from `github.token`.
     `--generate-notes` is deliberately **omitted** (its interaction with
     `--notes-file` varies across `gh` versions and could break the publish
     step); the release body is the static Gatekeeper note.
- **Release notes** (`Packaging/release-notes.md`) include the unsigned/
  un-notarized caveat: first launch via **right-click ▸ Open**, or
  `xattr -dr com.apple.quarantine Casper.app`.

### 3. Auto-update scaffolding (Sparkle-ready, not implemented)

The pipeline emits a **Sparkle-compatible `appcast.xml`** so a future Sparkle
integration reads it as-is. What is already correct by construction:

- **Artifact format:** `.zip` containing `Casper.app` at the top level — exactly
  Sparkle's expected enclosure.
- **Bundle layout:** `Contents/Frameworks/` + an `@executable_path/../Frameworks`
  rpath (set by dylibbundler) is precisely where `Sparkle.framework` will later
  be embedded — no bundle rework.
- **Stable feed URL:** `releases/latest/download/appcast.xml` always resolves to
  the newest release's asset — ideal as `SUFeedURL`.

Added now:

- **Monotonic `CFBundleVersion`** from `git rev-list --count HEAD`. This is the
  value Sparkle compares to decide "is there a newer build?"; setting it
  correctly from day one prevents broken update comparisons later.
- **`appcast.xml` generation.** The release job **fetches the previous
  `appcast.xml` from the latest release and prepends the new `<item>`**
  (newest-first, starting from an empty feed on the first release), then uploads
  the updated feed. Seeding is fail-safe: only a genuine **404** falls back to
  the empty template; any other HTTP status or transport error is **fatal**, so a
  transient network blip can never silently truncate the release history (with
  `curl --retry` for flaky connectivity). This avoids re-enumerating every
  release and keeps history intact. Each `<item>`
  carries `sparkle:version` (= `CFBundleVersion`),
  `sparkle:shortVersionString`, `pubDate`, and an `<enclosure>` with `url`,
  `length`, and a reserved `sparkle:edSignature="__TODO__"` slot (empty until an
  EdDSA key exists). `sha256` is published in the `.sha256` sidecar for manual
  verification in the meantime.

### Future step (documented, out of scope now)

Integrate Sparkle 2 via SPM into `CasperUI`; generate the EdDSA keypair with
Sparkle's `generate_keys`; sign each zip with `sign_update` in the release job
and inject the signature into the appcast; set `SUPublicEDKey` in `Info.plist`.
Note: for a Sparkle update to install past Gatekeeper cleanly the `.app` should
be signed — this milestone reintroduces signing/notarization, consistent with
deferring them today.

## Data Flow

```
git push tag v0.1.0
  └─ release.yml (macos-15, arm64)
       ├─ pinned Xcode + brew install libgit2 pkgconf dylibbundler
       ├─ swift build -c release            → bare casper binary
       ├─ bundle-app.sh                      → Casper.app
       │    ├─ binary → Contents/MacOS/casper
       │    ├─ Info.plist (versions substituted) → Contents/
       │    ├─ dylibbundler → Contents/Frameworks/ + @rpath rewrite
       │    └─ otool self-check (fail if any /opt/homebrew remains)
       ├─ make dist                          → Casper-0.1.0-arm64.zip + .sha256
       ├─ regenerate appcast.xml             → Sparkle feed
       └─ gh release create                  → assets attached to the v0.1.0 release
```

## Error Handling & Edge Cases

- **Residual Homebrew path:** the `otool` self-check fails the job before a
  broken artifact is ever published.
- **Xcode drift:** pinned Xcode version; a bump is an explicit, reviewed change.
- **Missing tag on manual run:** `workflow_dispatch` requires the `version` input;
  the job derives the same variables from it.
- **Gatekeeper:** unavoidable while unsigned — surfaced in the release notes, not
  silently ignored.

## Testing

- **Local:** `make dist`, then `otool -L Casper.app/Contents/MacOS/casper` shows
  only `@rpath` / system paths; unzip and launch.
- **CI:** the `bundle-app.sh` `otool` self-check runs in the job and is the
  publish gate. Optionally, a step copies `Casper.app` to a scratch dir and
  re-runs `otool -L` to confirm no `/opt/homebrew` reference survives relocation.
- The existing `ci.yml` continues to cover build + unit tests on PRs.

## Open Question Resolved

- **Bundle identifier:** `com.alexandreroman.casper` (adjustable during review).
- **otool self-check:** hard failure (not a warning) — it is the correctness gate
  for "runs on a clean Mac".
- **Auto-update target:** Sparkle-compatible `appcast.xml` (free, least app code
  to write later).
