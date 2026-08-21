# Notification Idle Best Practices — Design

**Date:** 2026-07-08 **Status:** Done — shipped (both repos; see commits in
each) **Scope:** Stop Casper (and the `casper-claude-plugin` hooks that drive
it) from raising a macOS notification for ordinary idle/turn-end events. Only
`blocked` (waiting on the user mid-task) and unseen `done` (task finished)
should notify; an ordinary `Stop` event on its own never should. Spans two
repos: this one (`Sources/CasperUI/AppModel.swift`,
`Sources/CasperUI/AppDelegate.swift`) and `casper-claude-plugin`
(`hooks/stop.sh`, `hooks/notification.py`).

## Problem

`casper-claude-plugin`'s `hooks/stop.sh` fires a macOS notification ("Claude is
done and waiting for you") on **every** Claude Code `Stop` event,
unconditionally — the same anti-pattern as Claude Code's own stock
`notification` hook, which announces "Claude is done and waiting for you" at
every turn end even when the agent isn't actually waiting on the user (e.g.
mid-plan, about to auto-continue). This duplicates Casper's own detection engine
(`themes/agent-state-detection.md`), which already derives an edge-triggered,
debounced `done` state (a `working → idle` transition while the workspace is
unseen) and independently notifies "Task finished" — so a single genuine
completion can produce two notifications, and every intermediate turn produces
one that shouldn't exist at all. `hooks/notification.py` compounds this: it
notifies for any `notification_type` it doesn't recognize, via a generic
fallback message, rather than staying silent by default.

Apple's HIG is explicit on both failure modes: a notification should carry
"timely, high-value information," and apps should "avoid sending multiple
notifications for the same thing" — repeated or unnecessary pings train people
to disable notifications for the app entirely.

## Goals

- A notification fires only when the user must act (`blocked`, `error`) or look
  at a result they haven't seen yet (unseen `done`).
- No notification for an ordinary turn boundary, an `idle` state the user has
  already seen, or an unrecognized/future Claude Code notification type.
- No duplicate notification for the same real-world event, whether the
  duplication comes from two independent producers (hook + detection engine) or
  a race between them.
- Presentation matches urgency: informational (`done`) is quieter than
  action-required (`blocked`/`error`).

## Non-Goals

- Building a detected producer for `error` (blocked on the libghostty
  shell-hosted-agent limitation documented in `themes/agent-state-detection.md`
  — agents run inside a plain login shell, so there's no agent-scoped exit event
  to observe).
- Requesting the `.timeSensitive` authorization option (Focus-mode breakthrough)
  — deferred until a concrete report of missed `blocked` notifications during
  Focus.
- A distinct signal to replace the dropped `idle_prompt` mapping — if a real gap
  shows up in practice (Claude Code idle 60s+ that Casper's own scraping doesn't
  catch), it needs its own design, not a reversion to the generic fallback.
- Changing notification content/format (title = workspace name, body = status
  message) — reviewed and kept as-is; no app name or "Workspace" prefix (macOS
  already supplies the app identity as system chrome).

## Criteria

| State           | Meaning                                | Notifies? | Interruption level | Message                  |
| --------------- | -------------------------------------- | --------- | ------------------ | ------------------------ |
| `working`       | agent actively executing               | No        | —                  | —                        |
| `idle` (seen)   | at rest, user has already looked       | No        | —                  | —                        |
| `done` (unseen) | task finished, not yet looked at       | **Yes**   | `.passive`         | "Task finished"          |
| `blocked`       | waiting on the user mid-task           | **Yes**   | `.active`          | "Waiting for your input" |
| `error`         | unrecoverable failure                  | **Yes**   | `.active`          | "Something went wrong"   |
| `unknown`       | nothing readable / no foreground agent | No        | —                  | —                        |

The deciding question: **does the user need to act, or look at something they
haven't seen?** A turn ending on its own is neither — it's only ever an input to
the detection engine, never a direct notification trigger.

## Design

### `casper-claude-plugin`

#### `hooks/stop.sh`

Drop the unconditional `casper notify` call. Keep only the status update —
Casper's detection engine (edge-triggered, debounced) becomes the sole trigger
for the "task finished" notification, via the existing
`working → idle (unseen) → done` derivation:

```bash
casper status set idle >/dev/null 2>&1 || true
```

#### `hooks/notification.py`

Replace "notify by default, skip known exceptions" with an allowlist — only the
two `notification_type`s that genuinely mean "waiting on the user mid-task" fire
anything; everything else, known or future, stays silent:

```python
BLOCKING_TYPES = {"permission_prompt", "elicitation_dialog"}

def main():
    payload = json.load(sys.stdin)
    notification_type = payload.get("notification_type", "")
    if notification_type not in BLOCKING_TYPES:
        return  # idle_prompt, auth_success, and any unknown/future type: silent
    subprocess.run(["casper", "status", "set", "blocked"], ...)
    message = FRIENDLY.get(notification_type, "Claude needs your attention")
    subprocess.run(["casper", "notify", "--message", message], ...)
```

`tests/test_notification.py` needs new/updated cases: `idle_prompt` → no
`casper notify` call; unknown `notification_type` → no call; the two
`BLOCKING_TYPES` → unchanged behavior (status `blocked` + notify).

### Casper

#### Message + interruption level (`Sources/CasperUI/AppModel.swift`)

`notificationMessage(for:)` (currently ~1198-1207) gains an `error` case and an
interruption level lookup:

```swift
private static func notificationMessage(for state: AgentState) -> String? {
    switch state {
    case .blocked: return "Waiting for your input"
    case .done: return "Task finished"
    case .error: return "Something went wrong"
    case .working, .idle, .unknown: return nil
    }
}

private static func interruptionLevel(for state: AgentState) -> UNNotificationInterruptionLevel {
    state == .done ? .passive : .active
}
```

`deliverNotification` (currently ~117-138) takes the level as a parameter and
sets `content.interruptionLevel`. For `.passive`, don't set `content.sound` —
the system ignores it for that level (no banner, no sound, silent addition to
Notification Center), so setting it would be dead code.

`.error` producing a message matters today even without a detected producer: the
explicit path (`casper status set error`, documented in the `casper-status`
skill) already exists and calls `casper notify` separately — this just means a
future detected producer (if `themes/agent-state-detection.md`'s libghostty
blocker is ever lifted) has a message ready.

No change to `AppDelegate.setupNotifications()`'s authorization options
(`[.alert, .sound]` stays as-is).

#### Per-workspace de-dup cooldown (`controlRaiseNotification`, ~1262-1286)

Track the last-delivered timestamp per workspace; ignore a new call within a
short window (~3s). This isn't required by the current design — explicit
`casper status set` already flips the workspace to `explicitAuthority`, which
stops the detection engine from also firing for it — but it's a cheap,
independent guard against the specific race where the hook's explicit
`casper notify` and a detection tick (250ms poll) both observe the same
on-screen event before authority flips, producing two notifications with
slightly different text for one real event. Matches the HIG "never two
notifications for the same thing" principle even if the current wiring shouldn't
hit it.

## Out of scope / deferred

- Detected producer for `error` — blocked on libghostty (see Non-Goals).
- `.timeSensitive` authorization — revisit only if `blocked` notifications are
  reported missed during Focus modes.
- Replacing the dropped `idle_prompt` signal — no compensation planned.
- `status.md` currently says the `blocked`/`done` → `casper notify` wiring is
  "deferred," while `themes/agent-state-detection.md` says it's built — that's a
  stale doc, not a design question; fix as a doc-only edit alongside this work.

## Testing

- `casper-claude-plugin`: update `tests/test_notification.py` per the allowlist
  above; manual/harness check that `stop.sh` no longer calls `casper notify`.
- Casper: extend `ControlHandlerTests.swift` — one case per state verifying
  message + interruption level, plus a case for the de-dup cooldown (two rapid
  calls for the same workspace → one delivered notification).
- Manual, via `debug-casper` and a real Claude Code session in a Casper
  terminal: an ordinary turn (no permission prompt, task still running) raises
  no notification; a permission prompt raises `.active` immediately; an unseen
  finished task arrives silently in Notification Center (no banner, no sound).
