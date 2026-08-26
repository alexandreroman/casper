---
name: "UNUserNotificationCenter aborts unbundled"
description: "UNUserNotificationCenter.current() crashes without a bundle id; a bundle-id guard skips notifications when unbundled. make dev carries a bundle id via Casper-dev.app so notifications work in dev"
type: reference
---

# UNUserNotificationCenter aborts unbundled

`UNUserNotificationCenter.current()` throws `NSInternalInconsistencyException`
("bundleProxyForCurrentProcess is nil") and `abort()`s on macOS 26 when the
process has no bundle identifier — it does **not** silently no-op, contrary to
older code comments. Any bare-executable run (`swift run`, a raw
`.build/.../debug/casper` launch) has no bundle id.

`AppModel.deliverNotification`'s default closure carries the bundle-id guard.
Every new `UserNotifications` call path needs the same one, whatever its
entry point.

The crash surfaces when a `casper notify --message` triggers a notification and
looks unrelated to whatever change is being tested — easy to misattribute. Same
family as other macOS-26 unbundled/abort gotchas (native `.inspector`,
`CGWindowListCreateImage`).

`make dev` launches through a real bundle (`Casper-dev.app`, bundle id
`com.github.alexandreroman.casper.dev`), so notifications do reach
`UNUserNotificationCenter.current()` there — a bare-binary launch is the only
path the guard silences.

**How to access:** to reproduce/observe under `make dev`, build, launch, then
`casper notify --message test --workspace <id>` (set `CASPER_CONTROL_SOCKET` to
`$TMPDIR/casper-control-<session>.sock` if not inside a real Casper terminal),
and watch
`/usr/bin/log stream --predicate 'subsystem == "com.apple.UserNotifications" OR
process == "casper"' --level debug`. See [[macos-notification-sound-cache-bug]]
for the separate stuck-custom-sound bug.
