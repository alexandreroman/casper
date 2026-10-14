---
name: "The idempotent-verb socket retry is deliberate"
description: "SocketClientEngine's idempotent-verb retry is a user decision; only the screenshot-loop discriminator justifies removing it"
type: feedback
---

# The idempotent-verb socket retry is deliberate

The retry `SocketClientEngine.send(…, retriable: true)` performs for idempotent
verbs is part of the design by the user's decision, although its original cause
is unconfirmed. Its mechanism, worst-case cost, cause and the discriminator
loop are on the `send` doc comment in
`Sources/CasperCore/SocketTransport.swift` and in `debug.md` § As-built notes,
"Idempotent-verb retry".

**Why:** whether the original cause still occurs is unmeasured, and removing
the retry on a reading of the code alone risks flaky `casper` calls for no
measured gain.

**How to apply:** a review must not delete the retry, `retriable:` at its CLI
call sites, or the `FlakyDebugServer` test without first running the
discriminator loop against a `make dev` instance, with the retry disabled. Zero
transport errors across the loop is the evidence that justifies removal; any
error is the cause the retry covers.
