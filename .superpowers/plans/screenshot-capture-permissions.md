# Stable Screen Recording permission for the debug build — Design

**Date:** 2026-07-08
**Status:** Proposed
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

`make dev` compounds this today by launching through `swift run casper --
--session …` rather than the compiled binary directly, which only matters
insofar as it's a second code path that should get the same fix.

This reproduces reliably: build, grant the permission, touch a source file,
rebuild, capture again — the grant is gone.

## Goals

- `.build/debug/casper` — however it's launched (`make build` +
  `debug-casper`'s direct exec, or `make dev`) — carries a **stable code
  signing identity** (a real Team ID) instead of the toolchain's default
  ad-hoc signature, so TCC's designated-requirement match survives rebuilds.
- Zero friction when no local signing identity is available: the build still
  succeeds, falls back to today's ad-hoc behavior, and prints a note pointing
  at the one-time setup below. Nobody's `make build` breaks because they
  haven't created a certificate.
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
- **No `.app` bundle wrapper for the debug binary.** TCC matches on the code
  signature's identifier + Team ID, not on the presence of a `CFBundleIdentifier`
  from an `Info.plist` — a loose, explicitly-identified Mach-O binary gets the
  same persistent grant a bundled app would, without the extra packaging step.
- **No scripted certificate provisioning.** Creating the Apple Development
  certificate is a manual, one-time, credential-bound step in Xcode; this
  plan documents it rather than automating it.

## Design

### Makefile — stable identity for the debug binary

Add a signing identity variable, auto-detected but overridable, and a
distinct bundle identifier for dev builds so it can never collide with the
release identifier (`com.alexandreroman.casper`, `Packaging/Info.plist`):

```make
# Local code-signing identity for debug builds (Screen Recording TCC
# persistence — see .superpowers/plans/screenshot-capture-permissions.md).
# Auto-detects the first "Apple Development" identity in the keychain;
# override with `make build CODESIGN_IDENTITY="Apple Development: ..."`.
# Empty means "no identity available" — falls back to the toolchain's
# default ad-hoc signature.
CODESIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null \
	| grep -m1 'Apple Development' | sed -E 's/.*"(Apple Development[^"]*)".*/\1/')
DEV_BUNDLE_ID := com.alexandreroman.casper.dev
```

Extend `build` to sign after compiling:

```make
## build: compile the debug build
build:
	swift build
	@if [ -n "$(CODESIGN_IDENTITY)" ]; then \
		codesign --force --sign "$(CODESIGN_IDENTITY)" \
			--identifier $(DEV_BUNDLE_ID) .build/debug/casper; \
	else \
		echo "note: no Apple Development signing identity found — casper" \
			"stays ad-hoc signed and Screen Recording permission will" \
			"reset on rebuild. Setup: .superpowers/plans/screenshot-capture-permissions.md"; \
	fi
```

`debug-casper`'s `SKILL.md` already does `make build` then execs
`.build/debug/casper` directly — it needs **no changes** and picks up the
fix automatically.

`dev` switches from `swift run` to the same signed binary, for consistency
(today it's the one path that doesn't already exec the built binary
directly):

```make
## dev: recompile and launch the app under a per-branch isolated dev session
dev: build
	@echo "==> dev session: $(DEV_SESSION)"
	.build/debug/casper --session $(DEV_SESSION)
```

### One-time local setup (documented, not automated)

1. Xcode → Settings → Accounts → sign in with any Apple ID (no paid Developer
   Program enrollment needed) → select the team → Manage Certificates → **+**
   → **Apple Development**.
2. `make build` now signs with it automatically (auto-detected).
3. Run a screenshot once (`casper debug screenshot /tmp/casper.png` per the
   `debug-casper` skill) and approve the Screen Recording prompt. Because the
   identifier `com.alexandreroman.casper.dev` is new, this is a fresh grant —
   not a reset of anything.
4. Subsequent rebuilds keep the grant. Stale entries left over from prior
   ad-hoc builds (listed under the bare executable name in System Settings →
   Privacy & Security → Screen Recording) are harmless orphans; remove them
   manually if desired, no functional impact.

### Caveat to verify empirically

Signing with a real identity (no hardened runtime enabled here — hardened
runtime is orthogonal to TCC identity stability and would risk complicating
debugger attach) shouldn't affect `lldb`/breakpoint workflows, but this has
not been tested on this machine and should be checked during implementation.

## Testing

Manual verification only — this is signing/build infra, not app logic:

1. Before setup: `security find-identity -v -p codesigning` shows no Apple
   Development identity → `make build` succeeds, prints the fallback note,
   `.build/debug/casper` is ad-hoc signed (`codesign -dv` shows
   `Signature=adhoc`).
2. Create the Apple Development certificate (steps above).
3. `make build` → `codesign -dv --verbose=4 .build/debug/casper` shows
   `Identifier=com.alexandreroman.casper.dev` and a real Team ID.
4. Run the `debug-casper` flow, capture a screenshot, approve the prompt once.
5. Touch a source file, `make build` again (new binary, different CDHash),
   capture again — **no new prompt**, capture succeeds immediately.
6. `make dev` launches and behaves identically to today (session flag,
   socket paths) — only the launch path changed, not the runtime behavior.
