---
name: "Agents cannot self-verify SwiftUI visual changes"
description: "Task/Agent subagents lack screen-recording (TCC) permission even when the interactive session's terminal has it, so toolbar/UI styling changes need human-provided screenshots, not agent self-verification"
type: feedback
---

# Agents cannot self-verify SwiftUI visual changes

Subagents dispatched via the Agent tool consistently report
`SCScreenshotManager`/`ScreenCaptureKit` failing with "The user declined TCCs
for application, window, display capture" when attempting
`casper debug screenshot`, even on a machine where the interactive session's
own terminal can capture successfully. This held across multiple independent
subagent dispatches while building the "Open in Editor" toolbar feature.

**Why:** screen-recording permission (see
[[debug-screenshot-screencapturekit]]) is granted per requesting process/TCC
identity, not inherited by whatever spawns a subagent — a subagent's sandbox
does not carry the interactive terminal's grant.

**How to apply:** for any visual/styling change (toolbar chrome, SwiftUI
layout, colors, icons), don't ask an implementer subagent to
screenshot-verify its own work — it will reliably fail and burn a turn. Have
the subagent build + `make build`/compile-verify only, then let the
**interactive session** (which can call the debug-casper screenshot tooling,
or more simply the user's own eyes via `make dev`) do the actual visual
check. Expect visual polish to be an iterative loop driven by the user's
screenshots, not something an agent confirms end-to-end alone.
