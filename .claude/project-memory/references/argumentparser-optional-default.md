---
name: argumentparser-optional-default
description: Do NOT add a custom init() to a ParsableCommand/Arguments to assign wrapped values — it crashes real .parse(). Test via .parse([...]), not direct construction.
type: reference
---

# argumentparser-optional-default

## The trap

Constructing a `ParsableCommand`/`ParsableArguments` struct DIRECTLY (e.g.
`var s = StatusCommand.Set(); s.state = "x"`) and reading a property-wrapper field
aborts with `Can't read a value from a parsable argument definition.`

The tempting "fix" — a custom `init()` that assigns the wrapped values
(`init() { self.workspace = nil }`, `self.state = ""`, etc.) — makes direct
construction work in tests but **crashes real parsing**. Assigning an
`@Option`/`@Argument`/`@OptionGroup` wrapped value puts the wrapper into a
"resolved value" state; when ArgumentParser later reads the argument *definition*
during `.parse()` / `.main()` it aborts:

```
ArgumentParser/Parsed.swift:68: Fatal error: Trying to get the argument set
from a resolved/parsed property.   (exit 133)
```

So the whole shipped command (and even its `--help`) crashes on invocation. Unit
tests that use direct construction pass and hide it, because they never call
`.parse()`.

## The correct approach

1. Give a `ParsableCommand`/`ParsableArguments` **no** custom `init()` that assigns
   wrapped values. Let ArgumentParser synthesize the init. Keep inline defaults on
   the declaration (`var total: Int = 0`, `var workspace: String?`).
2. Test via the supported parse path, never direct construction + field poking:
   ```swift
   let cmd = try StatusCommand.Set.parse(["waiting", "--workspace", "feature"])
   XCTAssertEqual(try cmd.makeCommand().state, "waiting")
   // validation cases: parse valid argv with a bad semantic value, assert build throws
   let bad = try ProgressCommand.Set.parse(
       ["--total","2","--current","5","--label","x","--workspace","f"])
   XCTAssertThrowsError(try bad.makeCommand())
   ```
   `.parse([...])` exercises the same path real usage takes, so it catches this
   class of bug.
3. Alternatively, extract each command's pure validation + `ControlCommand` building
   into a free/static function taking plain values and unit-test that directly,
   keeping the `ParsableCommand` a thin shell.

This applies to `WorkspaceTargetOption` (`Sources/CasperCLI/ControlClient.swift`)
and every domain command (`Status`/`Progress`/`Notify`/`Terminal`/`Browser`/`Diff`/
`Workspace`). See [[domain-cli-control-channel]].
