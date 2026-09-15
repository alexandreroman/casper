---
name: "macOS 26 appearance is gated on the linked SDK"
description: "macOS serves Liquid Glass only to a binary whose LC_BUILD_VERSION records SDK >= 26; SwiftPM records the deployment target there, so the Makefile passes -platform_version"
type: reference
---

# macOS 26 appearance is gated on the linked SDK

macOS 26 serves the Liquid Glass appearance only to a binary whose
`LC_BUILD_VERSION` load command records an **SDK of 26 or newer**. A binary
recording an older SDK is served the legacy pre-26 appearance instead: hard
black borders around the window and its panes, and a shorter title bar, so the
toolbar row Casper builds in `WorkspaceTitleBarRow` sits in noticeably less
height. The fallback is silent — nothing in the build output mentions it, the
binary is otherwise identical, and the difference reads as a regression in
Casper's own chrome rather than as a build-metadata problem.

SwiftPM's default build system (`swiftbuild`) writes that SDK field from the
**deployment target** rather than from the SDK it actually links against.
Measured with Xcode 27 / Swift 6.4 on a package declaring
`platforms: [.macOS(.v15)]`, against `MacOSX27.0.sdk`:

| build path | minos | sdk |
|---|---|---|
| `swift build` (default `swiftbuild`) | 15.0 | **15.0** |
| `swift build --build-system native` (deprecated) | 15.0 | 27.0 |
| `swiftc -target arm64-apple-macosx15.0` | 15.0 | 27.0 |

So the Makefile pins the field itself, through `SWIFT_PLATFORM_FLAGS`
(`-Xlinker -platform_version -Xlinker macos -Xlinker $(MACOS_DEPLOYMENT_TARGET)
-Xlinker $(MACOS_SDK_VERSION)`), carried by both the `build` and the `release`
target and folded into the exported `SWIFT_RELEASE_FLAGS`. The linker accepts
the explicit flag over the one SwiftPM supplies without a duplicate warning.
`MACOS_DEPLOYMENT_TARGET` duplicates `Package.swift`'s `platforms:` and has to
move with it — as does the standalone fallback in `Scripts/assemble-bundle.sh`,
which cannot read a Make variable and so carries a third copy of the deployment
target (`Scripts/bundle-app.sh` holds a fourth, for `actool`). Through `make`
the exported value always wins; the fallback only serves a direct run of the
script.

**Why:** the deployment floor and the linked SDK are independent — Casper
targets macOS 15 and must still be *built* against 26+ to get the current
appearance — and only the second of the two is what the OS reads. Raising the
deployment target to buy the appearance would drop macOS 15 support for nothing.

**How to access:** read the field back with
`vtool -show-build-version <binary> | grep -E 'minos|sdk'`, on
`.build/debug/casper` or on `Casper.app/Contents/MacOS/casper`. `sdk` below 26
means the running app shows the legacy appearance. `xcrun --show-sdk-version`
reports what a build would record. Apple's `UIDesignRequiresCompatibility`
Info.plist key is the opposite lever — an opt-*out* for apps built against 26+
— and has no place here.

Related: [[swift-toolchain-floor]], [[glasseffect-nested-menu-invisible]],
[[agent-visual-verification-limits]].
