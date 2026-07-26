# Sparkle auto-update

**Status: shipped.** Completes the auto-update scaffolding described in
[`github-release.md`](github-release.md) ("Future step"), minus code-signing
identity and notarization, which stay deliberately out of scope.

## Goal

Casper checks `appcast.xml` on the latest GitHub release, offers newer builds in
the UI, and installs them in place — with no Apple Developer account involved.

## Trust model (the one thing to get right)

Casper ships **ad-hoc signed**: no Developer ID certificate, no notarization.
Sparkle therefore cannot authenticate an update by code-signing continuity, and
the **EdDSA signature on the appcast enclosure is the only trust anchor**.

Sparkle explicitly supports this shape. Its update policy accepts a bundle when
"old and new Ed(DSA) public keys are the same and valid (it allows change of
Code Signing identity)", and its own error text names ad-hoc signing as the
minimum viable identity. Two consequences the packaging must respect:

- **The app must stay ad-hoc signed on both sides.** Sparkle rejects an update
  that *removes* a code signature when the installed copy has one. `make bundle`
  signs the executable and every bundled dylib, so every release is consistent
  with every other.
- **A release without a valid signature is worse than no release.** Every
  installed copy would reject it. The release workflow therefore *fails* when
  the signing secret is missing rather than publishing an unsigned feed.

Gatekeeper is not a problem for the update path: Sparkle clears the quarantine
attribute from the extracted bundle before swapping it in. The quarantine
caveat in `Packaging/release-notes.md` still applies to the *first*, manually
downloaded copy.

## Key management

The key pair is a plain Ed25519 pair in Sparkle's modern format: the private
half is the **base64 of the 32-byte seed**, the public half the base64 of the
32-byte public key.

- **Public key** — committed as `SUPublicEDKey` in `Packaging/Info.plist`. It is
  public by design; it only ever verifies.
- **Private seed** — the `SPARKLE_PRIVATE_KEY` repository secret. It exists
  nowhere in the repo. Losing it means generating a new pair and shipping one
  release signed with the *old* key that carries the *new* `SUPublicEDKey`
  (Sparkle supports key rotation, not removal); losing it silently and rotating
  without that bridge release strands every installed copy.

Regenerating the pair (only needed if the secret leaks or is lost):

```bash
"$(Scripts/sparkle-tool.sh generate_keys)"          # writes to the login keychain
"$(Scripts/sparkle-tool.sh generate_keys)" -x key.txt   # export for the CI secret
gh secret set SPARKLE_PRIVATE_KEY < key.txt && rm key.txt
```

Then copy the printed public key into `SUPublicEDKey`.

## Pieces

### App (`CasperUI`)

- `Package.swift` depends on `sparkle-project/Sparkle` — the fifth and last
  sanctioned external dependency.
- `SoftwareUpdater.swift` wraps `SPUStandardUpdaterController` behind a single
  gate: the updater is constructed **only** when the running bundle carries both
  `SUFeedURL` and `SUPublicEDKey`. `Packaging/Info-dev.plist` carries neither, so
  development builds — and `swift run casper`, which has no bundle at all — never
  talk to the network, never schedule a check, and never show the menu item.
- `MenuCommands.swift` adds **Check for Updates…** to the App menu via
  `CommandGroup(after: .appInfo)`, included only when the gate is open. The
  value is constant for the process lifetime, so this cannot reintroduce the
  menu-resync flicker that file's comments warn about.
- `AppDelegate.applicationDidFinishLaunching` starts the updater.

`Packaging/Info.plist` sets `SUEnableAutomaticChecks` and a daily
`SUScheduledCheckInterval`. `SUAutomaticallyUpdate` is left unset: Casper checks
in the background but never installs without the user agreeing.

### Bundle (`Scripts/bundle-app.sh`)

`Sparkle.framework` is copied from the SwiftPM artifact into
`Contents/Frameworks/` with `ditto`, which preserves the versioned-bundle
symlinks and the Apple signature sealing `Autoupdate`, `Updater.app` and the XPC
services nested inside. The binary's `@rpath` already points at
`Contents/Frameworks`, so no load-command surgery is needed.

`dylibbundler` is told to `--ignore` the artifact directory. Left alone it
resolves `@rpath/Sparkle.framework/Versions/B/Sparkle`, flattens that Mach-O to
`Contents/Frameworks/Sparkle` and repoints the binary at it — the app still
launches, but Sparkle finds its own resources through the bundle of its class,
which would become `Casper.app`, and every update fails. Two asserts guard
against a regression: no flat `Contents/Frameworks/Sparkle`, and the load
command still naming the framework.

### Tooling (`Scripts/sparkle-tool.sh`)

Prints the path to `sign_update` / `generate_keys` / `generate_appcast`. It
prefers the copy SwiftPM already unpacked next to the xcframework, and otherwise
downloads the tarball for the version read from `Package.resolved` — the tool
that signs can never drift from the framework that verifies.

### Release (`release.yml` + `Scripts/update-appcast.sh`)

1. `make dist` → `Casper-<v>-arm64.zip`.
2. `sign_update --ed-key-file` produces the EdDSA signature, then
   `--verify` re-checks it before it is used.
3. `update-appcast.sh` prepends the `<item>` — now carrying the real
   `sparkle:edSignature`, a `<link>` to the release page and a short
   `<description>` so the update dialog is not blank.
4. `gh release create/upload` publishes the zip, its `.sha256` and the feed.

## Testing

Unit tests cannot cover this: the gate keys off `Bundle.main`, and every
interesting failure lives in the packaging. Verified by construction instead:

- `make bundle` runs the two Sparkle asserts plus `codesign --verify` on the
  embedded framework, and the pre-existing `otool` relocation self-check now
  also covers the framework binary.
- The signature is verified in CI immediately after being produced.
- End to end, a real update can only be exercised by publishing two releases;
  the first tagged release after this change is the live test.

## Explicitly not done

**Developer ID signing and notarization.** They would let Sparkle validate
updates by code-signing continuity as well, and would remove the right-click ▸
Open dance on first download. They require a paid Apple Developer account and
certificates in CI, and the EdDSA anchor above is sufficient for update
integrity without them.
