---
name: "UNUserNotificationCenter aborts unbundled"
description: "UNUserNotificationCenter.current() crashes without a bundle id (make dev); guard on Bundle.main.bundleIdentifier"
type: reference
---

# UNUserNotificationCenter aborts unbundled

`UNUserNotificationCenter.current()` throws `NSInternalInconsistencyException`
("bundleProxyForCurrentProcess is nil") and `abort()`s on macOS 26 when the
process has no bundle identifier — i.e. any bare-executable run
(`make dev` / `swift run`, launched from `.build/.../debug/`). It does **not**
silently no-op as older code comments assumed. Bundled runs (`Casper.app`, via
`make bundle`) are unaffected because they carry a bundle id.

The live source is `Sources/CasperUI/AppModel.swift`, the `deliverNotification`
default closure. It is guarded with
`guard Bundle.main.bundleIdentifier != nil else { return }` before any
`.current()` access, so hook-driven notifications are skipped (not delivered)
under `make dev` instead of crashing on the first hook message that reaches
`handleHookMessage(_:now:)`.

**Why:** the crash surfaces at app startup when a queued hook message triggers a
notification, and it looks unrelated to whatever change is being tested — easy to
misattribute. Same family as other macOS-26 unbundled/abort gotchas (native
`.inspector`, `CGWindowListCreateImage`).

**How to access:** any new `UserNotifications` call path must keep the bundle-id
guard (or run only under a real bundle). To reproduce/observe, run `make dev` and
trigger a Claude Code hook from a Casper terminal.
