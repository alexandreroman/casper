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
default closure (reached via `controlRaiseNotification`, i.e. `casper notify
--message …`). It is guarded with
`guard Bundle.main.bundleIdentifier != nil else { return }` before any
`.current()` access, so notifications are skipped (not delivered) under
`make dev` instead of crashing.

**Why:** the crash surfaces when a `casper notify --message` triggers a
notification, and it looks unrelated to whatever change is being tested — easy to
misattribute. Same family as other macOS-26 unbundled/abort gotchas (native
`.inspector`, `CGWindowListCreateImage`).

**How to access:** any new `UserNotifications` call path must keep the bundle-id
guard (or run only under a real bundle). To reproduce/observe, run `make dev` and
`casper notify --message test` from a Casper terminal.

**Needs re-verification:** `make dev` now launches through a real bundle
(`Casper-dev.app`, see [[screenshot-capture-permissions]]), so
`Bundle.main.bundleIdentifier` is no longer nil under `make dev` — the guard
above will now let `casper notify` reach `UNUserNotificationCenter.current()`
instead of skipping it. Whether that actually delivers a notification cleanly
under `make dev`, or hits a different unbundled-adjacent abort, is untested;
confirm before relying on notifications working in dev builds.
