---
name: "MainActor isolated delegate conformance"
description: "A @MainActor class conforming to a non-@MainActor Cocoa delegate protocol needs an isolated `@MainActor` conformance"
type: reference
---

# MainActor isolated delegate conformance

When a `@MainActor` class conforms to a Cocoa delegate protocol that Apple has
**not** annotated `@MainActor`, Swift 6 rejects the plain conformance with:
`conformance of 'X' to protocol 'Y' crosses into main actor-isolated code and
can cause data races [#ConformanceIsolation]`. The fix is an isolated
conformance — spell the protocol `@MainActor Y` in the inheritance clause:

```swift
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, @MainActor UNUserNotificationCenterDelegate { … }
```

Same treatment as `GhosttySurfaceView: NSView, @MainActor NSTextInputClient`.

**Not every delegate needs this.** Protocols Apple already annotates `@MainActor`
(e.g. `WKNavigationDelegate`, used by `BrowserCoordinator`) conform with no extra
ceremony, because the isolation already matches. Only pre-concurrency /
un-annotated protocols (`UNUserNotificationCenterDelegate`, `NSTextInputClient`)
require the explicit `@MainActor` on the conformance. Do not assume a new
delegate behaves like `WKNavigationDelegate` — check whether its protocol is
`@MainActor`-annotated; if not, add the isolated conformance.

General mechanism is the Swift-6.2 isolated-conformances feature already noted in
the toolchain-floor memory; this note records the concrete delegate-protocol case.
