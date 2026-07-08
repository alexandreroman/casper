---
name: "UNUserNotificationCenter aborts unbundled"
description: "UNUserNotificationCenter.current() crashes without a bundle id; make dev now carries one via Casper-dev.app, so notifications work again in dev"
type: reference
---

# UNUserNotificationCenter aborts unbundled

`UNUserNotificationCenter.current()` throws `NSInternalInconsistencyException`
("bundleProxyForCurrentProcess is nil") and `abort()`s on macOS 26 when the
process has no bundle identifier. This applied to any bare-executable run in
the past (`swift run` / the old `.build/.../debug/casper` launch path); it
does **not** silently no-op as older code comments assumed.

The live source is `Sources/CasperUI/AppModel.swift`, the `deliverNotification`
default closure (reached via `controlRaiseNotification`, i.e. `casper notify
--message …`). It is guarded with
`guard Bundle.main.bundleIdentifier != nil else { return }` before any
`.current()` access, so notifications are skipped (not delivered) rather than
crashing whenever the process has no bundle id.

**Why:** the crash surfaces when a `casper notify --message` triggers a
notification, and it looks unrelated to whatever change is being tested — easy to
misattribute. Same family as other macOS-26 unbundled/abort gotchas (native
`.inspector`, `CGWindowListCreateImage`).

**Current status: `make dev` notifications work.** `make dev` now launches
through a real bundle (`Casper-dev.app`, bundle id
`com.github.alexandreroman.casper.dev` — see
[[screenshot-capture-permissions]]), so `Bundle.main.bundleIdentifier` is no
longer nil under `make dev`, and the guard above lets `casper notify` reach
`UNUserNotificationCenter.current()`. Confirmed empirically (2026-07-09):
`casper notify --message "…"` returned success, the process stayed alive (no
abort, no crash report), the log showed
`[com.apple.UserNotifications:Connections] […] Requested authorization
[ didGrant: 1 hasError: 0 … ]` followed by `Added notification request: [
hasError: 0 … ]`, and the notification banner was visibly delivered. The
bundle-id guard itself is unaffected and should stay (it's still needed for
any future launch path — e.g. a raw CLI invocation — that lacks a bundle).

**How to access:** any new `UserNotifications` call path must keep the
bundle-id guard. To reproduce/observe under `make dev`: build, launch, then
`casper notify --message test --workspace <id>` (set `CASPER_CONTROL_SOCKET`
to `$TMPDIR/casper-control-<session>.sock` if not running inside a real
Casper terminal), and watch `/usr/bin/log stream --predicate 'subsystem ==
"com.apple.UserNotifications" OR process == "casper"' --level debug`.
