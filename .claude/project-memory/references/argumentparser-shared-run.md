---
name: "ArgumentParser shared run() via a refining protocol"
description: "A protocol refining ParsableCommand can carry the default run(); Swift picks it over ArgumentParser's own default"
type: reference
---

# ArgumentParser shared run() via a refining protocol

Subcommands whose `run()` bodies are identical share one implementation through a
protocol that refines `ParsableCommand` and provides `run()` in its extension —
`WorkspaceRefCommand` in `Sources/CasperCLI/ControlClient.swift`, adopted by the
16 subcommands whose whole job is "send one control command, emit
`{"workspace":"<id>"}`".

`ParsableCommand` already ships a default `run()` (it throws a help request), so
two extension witnesses are visible on every conformer. Swift resolves the
conformance to the member from the more refined protocol, so the shared body wins
and the ArgumentParser fallback is never reached. Verify empirically after
touching this — a wrong witness compiles fine and only shows up at runtime as the
command printing its help text instead of acting:

```bash
env -u CASPER_WORKSPACE_ID -u CASPER_CONTROL_SOCKET ./.build/debug/casper notify --message hi
# {"error":"no target workspace: run inside a Casper terminal or pass --workspace"}
```

Per-command variation rides on a protocol requirement with a default (e.g.
`var commandTimeout: TimeInterval { get }`, defaulting to `sendControl`'s 5 s),
which conformers override — browser automation verbs to 15 s, `workspace delete`
to 35 s, `browser wait` to a value computed from its own `--timeout`.
