---
name: "Unused-import greps give false positives on extension members"
description: "An import can look unused yet be required: extension members and attribute scopes resolve module-wide, so compiling without it proves nothing"
type: reference
---

# Unused-import greps give false positives on extension members

Auditing imports by grepping a file for framework-prefixed names (`NS…`,
`SwiftUI` types) under-reports what the file actually needs. Two shapes carry no
framework name at the call site:

- **Attribute-scope accessors** — `attributes.swiftUI.foregroundColor` in
  `DiffTextAssembly.foregroundColor(in:)`, `stripped.swiftUI.font = nil` in
  `DiffHighlighter.droppingFonts(_:)`. Both require `import SwiftUI`.
- **Extension initializers and properties** — `NSColor(_: Color)` reads as a
  plain `NSColor` construction but is a SwiftUI-provided initializer.

Compiling after removing such an import is **not** evidence it was unused. Swift
scopes an import to its file only for top-level name lookup; an extension member
resolves as long as *any* file in the same module imports the framework. The
build stays green while the file silently depends on a sibling's import, and it
breaks later with the error pointing at this file instead of at the change that
caused it.

A third shape hides the dependency even from a careful read: an **implicit
member expression never names the type**.
`Color(nsColor: .windowBackgroundColor)` depends on `NSColor` without the
string `NSColor` appearing anywhere.

Confirm by reading what each member resolves to before deleting an import. A
genuinely unused import is one where no symbol, member or operator in the file
originates in that framework — not merely one the compiler tolerates losing.

When a single expression is the whole question, settle it by typechecking that
expression in a fresh **one-file** compilation unit importing only what the
audited file imports — an isolated unit has no sibling to leak an import from:

```bash
cat > probe.swift <<'EOF'
import SwiftUI
func probe() -> Color { Color(nsColor: .windowBackgroundColor) }
EOF
xcrun swiftc -typecheck -target arm64-apple-macos15.0 probe.swift
```

That probe passes: `Color(nsColor:)` and the `NSColor` static accessors resolve
under `import SwiftUI` alone, so a file whose only AppKit-looking code is that
expression needs no `import AppKit`.
