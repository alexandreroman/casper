# Stable Screen Recording permission for the debug build — Design

**Date:** 2026-07-08
**Status:** Done — implemented and verified end-to-end (see "Revision" and
"Testing" below for what changed from the original proposal and why)
**Scope:** Make the `debug-casper` skill's `screenshot` verb (and any future
Screen Recording use in a debug build) keep its macOS TCC grant across
`make build`/`make dev` rebuilds, instead of re-prompting (or silently
failing) after every recompile.

## Problem

`DebugServer.screenshot(window:to:)` (`Sources/CasperGhostty/DebugServer.swift:256-283`)
captures window pixels via ScreenCaptureKit's `SCScreenshotManager.captureImage`
— required because libghostty renders through Metal, so a plain AppKit view
snapshot would miss the real composited frame. Screen Recording permission is
therefore unavoidable; that is not the bug.

The bug is that the grant does not survive a rebuild. `make build` compiles
`.build/debug/casper` via `swift build`, which signs it **ad-hoc**
(`codesign --sign -`, no Team ID). macOS TCC identifies an ad-hoc-signed
binary by its **code directory hash (CDHash)**, not by a stable identifier —
and that hash changes on every recompilation. Each new build is therefore a
"new," unrecognized client as far as TCC is concerned: the Screen Recording
grant from the previous build does not carry forward, so the permission
prompt (or a silent capture failure, if the user doesn't notice the prompt)
recurs on the next `casper debug screenshot`.

This reproduces reliably: build, grant the permission, touch a source file,
rebuild, capture again — the grant is gone.

## Revision — a loose Mach-O binary never registers with TCC at all

The first implementation of this plan signed `.build/debug/casper` in place
(a bare executable, no `.app` bundle) with a stable local identity, on the
theory that TCC matches on code identifier + Team ID regardless of bundle
structure. **Empirically wrong.** Tested end-to-end on this machine:

- Signed the loose binary with a real `Apple Development` identity and a
  fixed `--identifier`. Screenshot capture still failed with
  `SCStreamErrorDomain Code=-3801 "The user declined TCCs..."` on the very
  first call — no system prompt ever appeared.
- Renaming the identifier (to rule out a naming collision) made no
  difference.
- Embedding an `NSScreenCaptureUsageDescription`-bearing `Info.plist`
  directly into the executable via linker `-sectcreate __TEXT __info_plist`
  (a real technique, confirmed working for other TCC services in a bare
  SwiftPM binary) made no difference either.
- Visually confirmed in System Settings → Privacy & Security → Screen &
  System Audio Recording: the loose binary **never appears in the list at
  all**, under any of the above configurations — only real `.app` bundles do
  (`Casper.app`, `Claude.app`, `Ghostty.app`, etc.).

Conclusion: for Screen Recording specifically, TCC/System Settings appears to
only enumerate and prompt for real `.app` bundles (`Contents/Info.plist` on
disk at a conventional path), not bare signed executables — regardless of
code identifier or embedded `__info_plist` section. This reverses this plan's
original "no `.app` bundle wrapper" non-goal: a minimal bundle is required,
not optional.

## Goals

- `make build` assembles a minimal, disposable **`Casper-dev.app`** wrapping
  `.build/debug/casper`, signed with a stable local code signing identity (a
  real Team ID) instead of the toolchain's default ad-hoc signature, so TCC's
  designated-requirement match survives rebuilds *and* the app is actually
  visible/grantable in System Settings.
- `make dev` and the `debug-casper` skill launch the binary **through that
  bundle** (`Casper-dev.app/Contents/MacOS/casper`), not the loose
  `.build/debug/casper` — running a bundle's own executable directly (no
  `open`/Finder needed) is sufficient for TCC to resolve the enclosing bundle
  and register it correctly; this is the same mechanism Xcode itself uses to
  launch Debug builds.
- Zero friction when no local signing identity is available: the build still
  succeeds, the bundle falls back to today's ad-hoc signature, and a note
  points at the one-time setup below. Nobody's `make build` breaks because
  they haven't created a certificate — they just keep today's re-prompt
  behavior (now at least visible in System Settings as `Casper-dev.app`,
  rather than invisible as before).
- Document the one-time local setup (free Apple Development certificate) so
  the fix is self-serve.

## Non-Goals

- **No change to `make release`/`make bundle`/`make dist` signing.** Those
  stay ad-hoc, per explicit scope decision — an Apple Development certificate
  only validates on the machine that created it and would fail Gatekeeper for
  any other user; making the shipped `.app` persist TCC grants across updates
  needs a paid Developer ID Application certificate + notarization, which is
  separate, larger work.
- **No Sparkle/notarization work.** `.superpowers/plans/github-release.md`
  already tracks Developer ID signing as a prerequisite for Sparkle
  auto-updates; this plan doesn't touch that. It's moot for the debug channel
  specifically anyway, since `DebugServer` is `#if DEBUG`-gated and never
  ships in a release/Sparkle-updated build.
- **No dylib bundling for `Casper-dev.app`.** Unlike `Scripts/bundle-app.sh`
  (which must make `Casper.app` relocatable to a clean Mac), `Casper-dev.app`
  only ever runs on the machine that built it, where Homebrew's libgit2 is
  already on the loader path exactly as it is for today's loose
  `.build/debug/casper`. No `dylibbundler`, no rpath surgery.
- **No scripted certificate provisioning.** Creating the Apple Development
  certificate is a manual, one-time, credential-bound step in Xcode; this
  plan documents it rather than automating it.

## Design

### Makefile — assemble and sign a minimal dev bundle

```make
# Local code-signing identity for debug builds (Screen Recording TCC
# persistence — see .superpowers/plans/screenshot-capture-permissions.md).
# Auto-detects the first "Apple Development" identity in the keychain;
# override with `make build CODESIGN_IDENTITY="Apple Development: ..."`.
# Empty means "no identity available" — falls back to an ad-hoc signature.
CODESIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null \
	| grep -m1 'Apple Development' | sed -E 's/.*"(Apple Development[^"]*)".*/\1/')
DEV_BUNDLE_ID := com.github.alexandreroman.casper.dev
DEV_APP := Casper-dev.app
```

(`com.github.alexandreroman.casper.dev` is the `.dev`-suffixed variant of
`com.github.alexandreroman.casper` — the single identifier now used
everywhere in the project: the `CasperLog` subsystem, and, following a
cleanup prompted by this work, the release bundle's `CFBundleIdentifier`
too (`Packaging/Info.plist`, previously the inconsistent
`com.alexandreroman.casper`). One name, one convention, no third variant.)

Extend `build` to assemble and sign `Casper-dev.app` after compiling:

```make
## build: compile the debug build and assemble the signed dev app bundle
build:
	swift build
	@rm -rf $(DEV_APP)
	@mkdir -p $(DEV_APP)/Contents/MacOS
	@cp .build/debug/casper $(DEV_APP)/Contents/MacOS/casper
	@sed -e "s/__DEV_BUNDLE_ID__/$(DEV_BUNDLE_ID)/g" \
		Packaging/Info-dev.plist > $(DEV_APP)/Contents/Info.plist
	@if [ -n "$(CODESIGN_IDENTITY)" ]; then \
		codesign --force --sign "$(CODESIGN_IDENTITY)" $(DEV_APP); \
	else \
		codesign --force --sign - $(DEV_APP); \
		echo "note: no Apple Development signing identity found — $(DEV_APP)" \
			"stays ad-hoc signed and Screen Recording permission will" \
			"reset on rebuild. Setup: .superpowers/plans/screenshot-capture-permissions.md"; \
	fi
```

New file **`Packaging/Info-dev.plist`** (minimal, no version placeholders —
this bundle is never distributed, so it doesn't need `SHORT_VERSION`/
`BUNDLE_VERSION` substitution):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>__DEV_BUNDLE_ID__</string>
	<key>CFBundleExecutable</key>
	<string>casper</string>
	<key>CFBundleName</key>
	<string>Casper (dev)</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>NSScreenCaptureUsageDescription</key>
	<string>The debug-casper skill captures a screenshot of the running app to verify UI changes during development.</string>
</dict>
</plist>
```

`debug-casper`'s `SKILL.md` needs a small update: its launch line changes
from `.build/debug/casper --session "$CASPER_SESSION" ...` to
`$(DEV_APP)/Contents/MacOS/casper --session "$CASPER_SESSION" ...` (the
`casper debug …` CLI invocations later in the skill are unaffected — those
are just socket clients, not launches).

`dev` launches through the bundle too:

```make
## dev: recompile and launch the app under a per-branch isolated dev session
dev: build
	@echo "==> dev session: $(DEV_SESSION)"
	$(DEV_APP)/Contents/MacOS/casper --session $(DEV_SESSION)
```

`Casper-dev.app/` is a build artifact: add `/Casper-dev.app/` to
`.gitignore` next to the existing `/Casper.app/` entry.

### One-time local setup (documented, not automated)

1. Xcode → Settings → Accounts → sign in with any Apple ID (no paid Developer
   Program enrollment needed) → select the team → Manage Certificates → **+**
   → **Apple Development**.
2. If this is the first certificate ever created on this Mac, Xcode is
   supposed to also install the current **WWDR intermediate certificate**
   automatically; empirically it did not on this machine (`security
   find-identity -v` kept reporting 0 valid identities — `codesign` failed
   with "unable to build chain to self-signed root"). If that happens,
   download the current WWDR intermediate from
   <https://www.apple.com/certificateauthority/> (`AppleWWDRCAG3.cer` for a
   `... OU=G3 ...`-issued leaf; check the leaf's issuer with `openssl x509
   -in <leaf.pem> -noout -issuer` if a newer generation is needed) and
   `security add-certificates -k login.keychain-db AppleWWDRCAG3.cer`.
3. `make build` now signs `Casper-dev.app` with it automatically
   (auto-detected).
4. **Launch the bundle via `open`, not a direct exec, for the very first
   grant.** `open "$(pwd)/Casper-dev.app" --args --session <name>` (add `-n`
   to force a fresh instance instead of reactivating one already running).
   Direct-exec (`Casper-dev.app/Contents/MacOS/casper --session <name>`)
   still works for every launch *after* the grant exists, and is what `make
   dev` and the `debug-casper` skill use — but empirically, the very first
   grant only reliably surfaced its consent dialog through an `open`-launched
   process. Run a screenshot once (`casper debug screenshot /tmp/casper.png`
   per the `debug-casper` skill); a standard system dialog appears asking to
   allow screen recording — approve it. The `casper debug screenshot`
   command blocks until you respond, so give it a minute.
5. If the screenshot still fails with `"The user declined TCCs..."` and
   `Casper-dev.app` never appears at all in System Settings → Privacy &
   Security → Screen & System Audio Recording, a **stale denial from an
   earlier attempt** is the likely cause (e.g. testing this feature before
   landing on the `.app`-bundle approach, with the same bundle identifier).
   Clear it with `tccutil reset ScreenCapture com.github.alexandreroman.casper.dev`
   (this also kills any running instance) and repeat step 4.
6. Subsequent rebuilds keep the grant automatically, since `Casper-dev.app`'s
   identifier and Team ID don't change between builds even though the binary
   inside it does — confirmed empirically: capture, touch a source file,
   `make build`, capture again with no prompt and no Settings interaction.

### Resolved caveats

`SCScreenshotManager.captureImage` **does** surface the standard system
consent dialog on first use, but only through a properly LaunchServices-
launched process (`open`); a plain fork/exec of the bundle's own binary from
a shell did not trigger it in testing, and neither did a raw loose Mach-O
binary (signed or not, with or without an embedded `__info_plist` section) —
the latter never even appeared in System Settings' list, confirming the
"Non-Goals" revision above. Once granted, direct-exec launches of the signed
bundle pick up the grant fine — the `open` requirement is a first-grant-only
concern, not a standing constraint on `make dev`.

Still unverified: whether signing with a real identity (no hardened runtime
enabled here, to avoid complicating debugger attach) affects `lldb`/
breakpoint workflows against the bundled binary.

## Testing

Manual verification, all steps run and confirmed on this machine:

1. Before setup: no Apple Development identity → `make build` succeeds,
   assembles `Casper-dev.app` ad-hoc signed, prints the fallback note. ✅
2. Created the Apple Development certificate; needed the WWDR intermediate
   fix (steps above) since it wasn't auto-installed. ✅
3. `make build` → `codesign -dv --verbose=4 Casper-dev.app` shows
   `Identifier=com.github.alexandreroman.casper.dev` and
   `TeamIdentifier=3L84M9W34L` (real, not adhoc). ✅
4. Launched via `open -n Casper-dev.app --args --session <test>` (required
   for the first grant's dialog to actually surface — see "Resolved
   caveats"), ran the `debug-casper` flow, captured a screenshot. Confirmed
   `Casper-dev.app` (not a loose binary) is what appears in System Settings;
   granted it. ✅
5. Touched a source file, `make build` again (new binary inside the same
   bundle, confirmed different CDHash via `codesign -dv`), captured again via
   a freshly launched process — **no new prompt, no Settings interaction**,
   capture succeeded immediately. This is the core fix, confirmed working. ✅
6. `make -n dev` dry-run confirms it launches
   `Casper-dev.app/Contents/MacOS/casper --session $(DEV_SESSION)` — same
   session-flag/socket-path behavior as before, only the launch path changed.
   (`make dev` itself not run live — it blocks on a GUI app — but it now
   shares the exact same direct-exec-of-the-bundle-binary path already
   verified working for repeat launches in step 5.) ✅
