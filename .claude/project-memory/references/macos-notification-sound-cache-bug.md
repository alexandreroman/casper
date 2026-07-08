---
name: "macOS notification sound cache bug"
description: "Custom UNNotificationSound silently falls back to the default macOS sound; root cause is an OS-level cache, not app code or signing"
type: project
---

# macOS notification sound cache bug

Casper's custom notification sound (`NotificationAlert.aiff`, delivered via
`UNNotificationSound(named:)` in `Sources/CasperUI/AppModel.swift`) can silently
fall back to the default macOS alert sound even though the bundle correctly
contains the sound file, both `.alert` and `.sound` authorization are granted,
and the banner displays normally. This is a known **macOS system-level bug**
(Apple Developer Forums thread 716650, Radar FB11642483), not a Casper defect —
it reproduces regardless of app code signing (confirmed: signing the release
`Casper.app` with a real local "Apple Development" identity instead of ad-hoc
made no difference to the symptom).

Confirmed workaround: System Settings → Sound → Sound Effects → turn off "Play
user interface sound effects" → delete the app → reboot → turn the setting back
on → reinstall/rebuild the app. A full reboot + reinstall was sufficient in
practice to clear the stuck state and get the custom sound playing.

**Why:** saves re-diagnosing this from scratch — code signing is a dead end
here, and the fix requires a disruptive user-driven reboot, not a code change.

**How to apply:** if a future report says "notification banner + default sound
plays, but not the custom one," skip signing/code investigation and go straight
to recommending this System Settings toggle + reboot + reinstall sequence. See
also [[unusernotificationcenter-unbundled-abort]] for the separate,
already-fixed "no notification at all" bug (missing bundle id in dev builds).
Also: `Scripts/bundle-app.sh`/`Makefile`'s release `bundle` target intentionally
stay **unconditional ad-hoc** signing — a real personal "Apple Development"
certificate is not portable to other machines and was reverted after this
investigation disproved it as the fix.
