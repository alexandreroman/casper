---
name: "Control verb exhaustive switch"
description: "Adding a ControlCommand.Verb case and routing it cannot be split across plan tasks/commits"
type: project
---

# Control verb exhaustive switch

`ControlServer.handle`'s workspace-scoped `switch command.verb { ... }` in
`Sources/CasperUI/ControlServer.swift` enumerates every `ControlCommand.Verb`
case with no `default:` fallback. Adding a new `Verb` case in `CasperCore`
therefore breaks `CasperUI`'s (and anything downstream, including `casper`'s
executable target and `CasperUITests`) compilation immediately, even though
`CasperCore` itself still builds and its own tests still pass in isolation.

A plan that splits "add the verb" and "route the verb to an `AppModel`
handler" into separate tasks cannot land as separate commits: the first
task's commit alone leaves the whole app (and its test target) unbuildable.
Those two tasks must be implemented and committed together as one commit —
an exception to the [implementation workflow](implementation-workflow.md)'s
default of one commit per plan task.

The first `switch command.verb { ... }` in the same function (the
not-workspace-scoped commands like `workspaceList`/`workspaceNew`) does have
a `default: break`, so adding a verb that is dispatched only from there is
not subject to this constraint — only the workspace-scoped switch is fully
exhaustive.
