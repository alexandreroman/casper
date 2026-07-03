---
name: "Observed startup dependencies"
description: "Startup-set @Observable properties a view gates rendering on must NOT be @ObservationIgnored; live-verify the restore path"
type: feedback
---

# Observed startup dependencies

An `@Observable` model property that is **assigned once at startup** (e.g.
`AppModel.runtime`, set in `applicationDidFinishLaunching`) and **read by a view
to gate what it renders** must NOT be marked `@ObservationIgnored`. If it is, a
view that reads it while still `nil` renders a fallback (e.g. `Color.black`), and
the later assignment triggers **no re-render** — so the fallback is permanent.

**Why:** on a **restored session**, SwiftUI can render the detail hierarchy
before the delegate finishes assigning the dependency, so the view samples the
`nil`. Only an observed property re-renders the view when the value arrives.
This bit `AppModel.runtime`: restored terminals stayed pure black until `runtime`
was made observed.

**How to apply:**
- Do not `@ObservationIgnored` a startup-provided dependency that a view body
  reads to decide rendering; leave it observed so its assignment re-renders.
- **Live-verify the restore-at-launch path separately** from the
  create-after-launch path — they exercise different timing. UI-1's live check
  only covered *Add folder* after launch (runtime already set), so this bug hid
  until a persisted multi-terminal session was reopened.
- Use the [[debug-casper]]-style channel to confirm: `dump-state` shows whether a
  surface exists and its size; `read-text`/`screenshot` show whether it paints.
  This works in a normal local session even when the agent itself launches the
  app.
