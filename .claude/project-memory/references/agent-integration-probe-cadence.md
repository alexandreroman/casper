---
name: "Agent-integration probe cadence"
description: "The launch probe pays the cold shell PATH probe; the detection tick refreshes it every few seconds"
type: project
---

# Agent-integration probe cadence

The integration probe runs in two distinct roles.

**The launch probe is the expensive one.** `AppDelegate` calls
`AppModel.refreshAgentIntegrations()` once at startup; that call resolves the
three agent CLIs through `LoginShellPath`, whose single shell `PATH` probe — a
few spawns, a few tenths of a second on a machine with a populated profile — is
shared by all three and bounded as a whole by `LoginShellPath.lookupTimeout`.
`LoginShellPath` caches that search path, and every answer drawn from it —
misses included — for the lifetime of the process, so each later probe is a
handful of `stat`/`read` calls and spawns nothing.

That probe is deliberately interactive as well as login, which is what it costs
rather than an inefficiency to trim: see [[shell-path-resolution]] for why a
login-only shell cannot see the `PATH` the user has in a terminal.

**Every later probe is a refresh, and it is cheap.** `runAgentDetectionTick()`
calls `refreshAgentIntegrationsIfStale()` on each pass, so the check rides the
existing detection loop rather than a timer of its own.
`agentIntegrationProbeInterval` is measured in **seconds**: the integration is
installed by a `plugin install` command typed in a Casper terminal, so Casper
never resigns active and `applicationDidBecomeActive` alone cannot retire the
sidebar line while the user watches for it. Opening a reminder's documentation
calls `agentReminderDocumentationOpened()`, which ages the result out so the
next tick re-probes.

`shouldRefreshAgentIntegrations(lastProbeAt: nil, …)` is **false**: with no
earlier result there is nothing to refresh, and starting the cold probe belongs
to the launch path. That also keeps every unit test that drives the detection
tick off the real filesystem.

**Why:** a minutes-long throttle silences the feedback loop exactly when the
user is watching for confirmation, and its stated cost is paid once, not per
probe.

**How to apply:** keep `refreshAgentIntegrations()` as the un-throttled entry
point, and never let the stale check start the first probe. See
[[agent-integration-policy]].
