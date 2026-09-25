---
name: "A release is dry-run and signature-checked before tagging"
description: "CI never bundles, and the workflow's own --verify never checks SUPublicEDKey; a dry-run plus an openssl check covers both"
type: reference
---

# A release is dry-run and signature-checked before tagging

Every `v*` tag is preceded by a dry-run of `.github/workflows/release.yml`
through `workflow_dispatch`. It runs the full job (tests, `make dist`, Sparkle
signing, appcast generation) but skips the publish step and uploads the zip,
its `.sha256`, the dSYM, `appcast.xml` and `release-description.md` (the
release description, previewable before tagging) as a build artifact instead.

**Why:** two gaps make a green CI insufficient.

- `ci.yml` runs only `swift build` and `make test`, never `make bundle`, so a
  packaging regression (actool, dylibbundler, Sparkle staging) surfaces only
  on the release job.
- The workflow's `sign_update --verify` checks the signature against the key
  derived from the private seed itself, never against `SUPublicEDKey` in
  `Packaging/Info.plist`. A seed that does not match the committed public key
  passes the workflow and strands every installed copy
  (see [[sparkle-eddsa-key]]). The seed is not in the local keychain, so the
  published artifact is the only place the match can be proven.

**How to access:**

```bash
gh workflow run release.yml -f version=<X.Y.Z>
gh run download <run-id> -D <dir>   # zip under <dir>/Casper-<X.Y.Z>-arm64/dist/
```

Then verify the enclosure's `sparkle:edSignature` from `appcast.xml` against
`SUPublicEDKey` with OpenSSL. The raw 32-byte key is wrapped in the Ed25519
SPKI DER prefix `302a300506032b6570032100`:

```bash
{ printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'
  printf '%s' "$PUB" | base64 -D; } > pub.der
openssl pkey -pubin -inform DER -in pub.der -out pub.pem
printf '%s' "$SIG" | base64 -D > sig
openssl pkeyutl -verify -pubin -inkey pub.pem -rawin -in Casper-<X.Y.Z>-arm64.zip -sigfile sig
```

Tag the exact commit the dry-run built: `CFBundleVersion` is
`git rev-list --count HEAD`, so any later commit changes the build number.
