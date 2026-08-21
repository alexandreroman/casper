---
name: "Casper.app is sealed with a non-deep ad-hoc codesign"
description: "bundle-app.sh signs nested dylibs, the executable, then the bundle itself — never with --deep, which would destroy Sparkle's Apple signature"
type: reference
---

# Casper.app is sealed with a non-deep ad-hoc codesign

`Scripts/bundle-app.sh` signs in a fixed order: the bundled dylibs, then the
main executable, then the bundle itself (`codesign --force --sign - "$APP"`).
The last step is what seals `Contents/Resources` (Assets.car, the icns, the
notification sound) and `Info.plist`; without it `codesign --verify Casper.app`
fails even though every Mach-O inside is signed.

The bundle signature is deliberately **not** `--deep`. `Contents/Frameworks/
Sparkle.framework` keeps the Apple signature it shipped with, which seals
`Autoupdate`, `Updater.app` and the nested XPC services that Sparkle launches as
separate processes during an install. `--deep` would replace that signature with
an ad-hoc one and break every update at the very last step. The script asserts
the framework's signature survives (`codesign --verify` on the framework) right
after signing the bundle, alongside `codesign --verify --strict "$APP"`.

Release bundles are ad-hoc signed only — no Developer ID, no notarization — so
Sparkle's sole trust anchor is `SUPublicEDKey` in `Packaging/Info.plist`, not
code-signing continuity.
