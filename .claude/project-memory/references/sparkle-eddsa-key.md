---
name: "Sparkle's EdDSA key rotates but never disappears"
description: "Losing the private seed strands every installed copy unless a bridge release ships first; where each half lives and how to regenerate"
type: reference
---

# Sparkle's EdDSA key rotates but never disappears

Casper ships ad-hoc signed, so the appcast's EdDSA signature is the only thing
authenticating an update. The pair is a plain Ed25519 pair in Sparkle's modern
format: the private half is the base64 of the 32-byte **seed**, the public half
the base64 of the 32-byte public key.

- **Public key** — committed as `SUPublicEDKey` in `Packaging/Info.plist`. It is
  public by design; it only ever verifies.
- **Private seed** — the `SPARKLE_PRIVATE_KEY` repository secret, and it exists
  nowhere in the repository.

**Why it matters:** Sparkle supports key *rotation* but not *removal*. An
installed copy only trusts the `SUPublicEDKey` it already has, so a new key
reaches users solely through a release signed with the **old** key that carries
the **new** `SUPublicEDKey`. Lose the seed without shipping that bridge release
first and every installed copy is stranded — it will reject every future update
and can only be replaced by a manual download.

**How to access:** the public half is in `Packaging/Info.plist`; the private
half is a GitHub Actions secret, consumed by `Scripts/sparkle-tool.sh` and
`Scripts/update-appcast.sh` from `.github/workflows/release.yml`, whose signing
step points here when it fails. Regenerate only if the secret leaks or is lost:

```bash
"$(Scripts/sparkle-tool.sh generate_keys)"              # writes to the login keychain
"$(Scripts/sparkle-tool.sh generate_keys)" -x key.txt   # export for the CI secret
gh secret set SPARKLE_PRIVATE_KEY < key.txt && rm key.txt
```

Then copy the printed public key into `SUPublicEDKey` — and ship the bridge
release described above before the old key stops being used.

Gatekeeper is not a concern on the update path: Sparkle clears the quarantine
attribute from the extracted bundle before swapping it in. The quarantine caveat
in `Packaging/release-notes.md` applies only to the first, manually downloaded
copy. See [[app-bundle-codesign-seal]] for the signing seal the bundle needs.
