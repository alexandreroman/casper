---
name: "The idempotent-verb socket retry stays"
description: "SocketClientEngine's bounded retry for idempotent verbs is deliberate; removing it needs the screenshot-loop discriminator"
type: feedback
---

# The idempotent-verb socket retry stays

`SocketClientEngine.send(…, retriable: true)` in
`Sources/CasperCore/SocketTransport.swift` retries a transport failure over a
fresh connection, up to `maxRetriableAttempts` (4) with a 50 ms backoff. The
retry is a deliberate part of the design, on both the control and the debug
channel, even though its cause is unconfirmed.

Its documented cause is an intermittent cross-process `ENETDOWN` before any
reply byte arrives while a slow handler such as `screenshot` runs (44efe2a).
The server-side linger until the client closes (dd82b81) fixes the same
`ENETDOWN` family mid-read and may cover the pre-reply case too; no
measurement says either way.

**Why:** the cost is bounded. The retry fires only on a `SocketTransportError`
reported before the timeout — a refused or dropped connection — and never on a
reply timeout (`SocketReplyTimeout` throws at once) or on a decoded response,
so it adds at most three backoffs and three fast-failing attempts, and a
mutating verb is never sent twice. Deleting it on a reading of the code alone
risks flaky `casper debug` calls for no measurable gain.

**How to apply:** a review must not delete the retry, `retriable:` at its CLI
call sites, or the `FlakyDebugServer` test without first running the
discriminator: disable the retry locally, then loop a few hundred
`casper debug screenshot` and `casper debug read-text --scrollback` calls
against a `make dev` instance, watching for transport errors. Zero errors
across the loop is the evidence that justifies removal; any error is the cause
the retry covers. The code comment on `send` and `debug.md` state the same
rule.
