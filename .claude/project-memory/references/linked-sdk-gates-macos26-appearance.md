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

| build path                                       | minos | sdk      |
| ------------------------------------------------ | ----- | -------- |
| `swift build` (default `swiftbuild`)             | 15.0  | **15.0** |
| `swift build --build-system native` (deprecated) | 15.0  | 27.0     |
| `swiftc -target arm64-apple-macosx15.0`          | 15.0  | 27.0     |

So the Makefile pins the field itself, through `SWIFT_PLATFORM_FLAGS`
(`-Xlinker -platform_version -Xlinker macos -Xlinker $(MACOS_DEPLOYMENT_TARGET)
-Xlinker $(MACOS_SDK_VERSION)`), carried by both the `build` and the `release`
target. The linker accepts the explicit flag over the one SwiftPM supplies
without a duplicate warning. The flags never reach `swift build
--show-bin-path`: the bin dir it prints depends only on the configuration.

The deployment target has two sources that move together: `Package.swift`'s
`platforms:` and `LSMinimumSystemVersion` in `Packaging/Info.plist`. Every
packaging step reads the plist — `MACOS_DEPLOYMENT_TARGET` in the Makefile, the
`actool` pass in `Scripts/bundle-app.sh` and the appcast's
`sparkle:minimumSystemVersion` in `Scripts/update-appcast.sh` — so a standalone
run of either script reads it too. A manifest cannot read a plist, which leaves
`Package.swift` as the one hand-kept copy. `Packaging/Info-dev.plist` carries no
`LSMinimumSystemVersion`: the dev bundle runs only on the Mac that built it,
where dyld enforces the binary's `minos` anyway.

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
