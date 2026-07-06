---
name: argumentparser-optional-default
description: ParsableArguments Optional @Option needs an explicit self.x = nil in init(), or unit tests crash
type: reference
---

# argumentparser-optional-default

`swift-argument-parser` 1.5.0 (pinned in `Package.swift`) does not treat a bare
`@Option var workspace: String?` as implicitly defaulting to `nil` when the
struct is constructed directly (not via `.parse()`/`.parseAsRoot()`), even
with `= nil` added to the declaration. Reading the property before parsing
aborts the whole test process with:

```
Can't read a value from a parsable argument definition.
```

Fix: give the type a custom `init()` that explicitly assigns every
`@Option`/`@Flag`/`@Argument` property, e.g.:

```swift
struct WorkspaceTargetOption: ParsableArguments {
    @Option(name: .long, help: "...")
    var workspace: String?

    init() {
        self.workspace = nil
    }
}
```

Why: any `ParsableArguments`/`OptionGroup` type meant to be constructed
directly in unit tests (not only parsed from `CommandLine.arguments`) needs
this pattern — `Sources/CasperCLI/ControlClient.swift`'s
`WorkspaceTargetOption` is the first instance; later CLI domain commands that
add their own target options should follow the same shape.
