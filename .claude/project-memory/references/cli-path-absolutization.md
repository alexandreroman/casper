---
name: "Control-socket paths are absolutized CLI-side"
description: "The GUI app's cwd is / when launched from Finder, so the casper CLI resolves relative filesystem paths before sending them"
type: reference
---

# Control-socket paths are absolutized CLI-side

Filesystem paths cross the control channel as plain strings
(`ControlCommand.path` for `browser screenshot --out`, `ControlCommand.cwd` for
`terminal new --working-dir`). The receiving side is the GUI app, whose working
directory is `/` when it was launched from Finder or the Dock — so a relative
path resolves against `/`, not the user's shell.

The CLI is the only side that still knows the caller's directory, so it resolves
every path there, via `absolutePath(_:)` in
`Sources/CasperCLI/ControlClient.swift`
(`URL(fileURLWithPath:relativeTo:).standardizedFileURL.path` against
`FileManager.default.currentDirectoryPath`). Resolving CLI-side also makes the
echoed JSON report the path the file actually landed at.

Any new verb carrying a filesystem path routes it through `absolutePath` in its
`makeCommand()`. Tests pin this through `.parse([...])` + `makeCommand()` — see
[[argumentparser-optional-default]] for why direct construction is not an
option.
