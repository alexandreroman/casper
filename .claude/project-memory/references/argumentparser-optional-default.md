---
name: argumentparser-optional-default
description: DO NOT add a custom init() to ParsableCommand/Arguments to assign wrapped values — it crashes real .parse(). Test via .parse([...]), not direct construction.
type: reference
---

# argumentparser-optional-default

**⚠️ This note previously prescribed a fix that CRASHES the real CLI. Corrected
2026-07-06 after a live smoke.**

## The trap

Constructing a `ParsableCommand`/`ParsableArguments` struct DIRECTLY (e.g.
`var s = StatusCommand.Set(); s.state = "x"`) and reading a property-wrapper
field aborts with:

```
Can't read a value from a parsable argument definition.
```

The tempting "fix" — a custom `init()` that assigns the wrapped values
(`init() { self.workspace = nil }`, `self.state = ""`, `self.target =
WorkspaceTargetOption()`) — makes direct construction work in tests **BUT
CRASHES REAL PARSING**. Assigning a `@Option`/`@Argument`/`@OptionGroup`
wrapped value puts the wrapper into a "resolved value" state; when
ArgumentParser later reads the argument *definition* during `.parse()` /
`.main()` it hits:

```
ArgumentParser/Parsed.swift:68: Fatal error: Trying to get the argument set
from a resolved/parsed property.   (exit 133)
```

So the whole shipped command (and even its `--help`) crashes on invocation.
Unit tests that use direct construction pass, hiding it, because they never
call `.parse()`.

## The correct approach

1. **Do NOT** give a `ParsableCommand`/`ParsableArguments` a custom `init()`
   that assigns wrapped values. Let ArgumentParser synthesize the init. Keep
   inline defaults on the declaration (`var total: Int = 0`, `var workspace:
   String?`) — those are the correct default mechanism.
2. **Test via the supported parse path**, never direct construction + field
   poking:
   ```swift
   let cmd = try StatusCommand.Set.parse(["waiting", "--workspace", "feature"])
   XCTAssertEqual(try cmd.makeCommand().state, "waiting")
   // throwing/validation cases: parse valid argv with a bad semantic value,
   // then assert the build step throws:
   let bad = try ProgressCommand.Set.parse(
       ["--total","2","--current","5","--label","x","--workspace","f"])
   XCTAssertThrowsError(try bad.makeCommand())
   ```
   `.parse([...])` exercises the same path real usage takes, so it catches
   this class of bug.
3. Alternatively, extract each command's pure validation + `ControlCommand`
   building into a free/static function taking plain values, and unit-test
   that directly — keeping the `ParsableCommand` a thin shell.

Affected files when this was discovered: `Sources/CasperCLI/ControlClient.swift`
(`WorkspaceTargetOption`) and every domain command
(`StatusCommand`/`ProgressCommand`/`NotifyCommand`/`TerminalCommand`/
`BrowserCommand`/`DiffCommand`/`WorkspaceCommand`). See
`[[domain-cli-control-channel]]`.
