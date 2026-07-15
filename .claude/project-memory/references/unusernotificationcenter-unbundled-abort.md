---
name: "UNUserNotificationCenter aborts unbundled"
description: "UNUserNotificationCenter.current() crashes without a bundle id; a bundle-id guard skips notifications when unbundled. make dev carries a bundle id via Casper-dev.app so notifications work in dev"
type: reference
---

# UNUserNotificationCenter aborts unbundled

`UNUserNotificationCenter.current()` throws `NSInternalInconsistencyException`
("bundleProxyForCurrentProcess is nil") and `abort()`s on macOS 26 when the process
has no bundle identifier — it does **not** silently no-op, contrary to older code
comments. Any bare-executable run (`swift run`, a raw `.build/.../debug/casper`
launch) has no bundle id.

The live source is `Sources/CasperUI/AppModel.swift`, the `deliverNotification`
default closure (reached via `controlRaiseNotification`, i.e. `casper notify
--message …`). It is guarded with `guard Bundle.main.bundleIdentifier != nil else {
return }` before any `.current()` access, so notifications are skipped (not
delivered) rather than crashing whenever the process lacks a bundle id. Any new
`UserNotifications` call path must keep this guard.

The crash surfaces when a `casper notify --message` triggers a notification and
looks unrelated to whatever change is being tested — easy to misattribute. Same
family as other macOS-26 unbundled/abort gotchas (native `.inspector`,
`CGWindowListCreateImage`).

`make dev` launches through a real bundle (`Casper-dev.app`, bundle id
`com.github.alexandreroman.casper.dev`), so `Bundle.main.bundleIdentifier` is
non-nil and the guard lets `casper notify` reach
`UNUserNotificationCenter.current()` — notifications work under `make dev`. The
guard stays regardless, for any future launch path (e.g. a raw CLI invocation) that
lacks a bundle.

**How to access:** to reproduce/observe under `make dev`, build, launch, then
`casper notify --message test --workspace <id>` (set `CASPER_CONTROL_SOCKET` to
`$TMPDIR/casper-control-<session>.sock` if not inside a real Casper terminal), and
watch `/usr/bin/log stream --predicate 'subsystem == "com.apple.UserNotifications"
OR process == "casper"' --level debug`. See [[macos-notification-sound-cache-bug]]
for the separate stuck-custom-sound bug.
