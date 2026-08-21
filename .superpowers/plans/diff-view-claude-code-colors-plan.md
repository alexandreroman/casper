# Diff View: Match Claude Code's Colors Implementation Plan

> **✅ DONE — shipped.** The diff-view restyle (HighlightSwift +
> `DiffHighlighter.swift`) is implemented and merged. This plan is retained for
> reference.

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restyle Casper's diff view so its row backgrounds, `+`/`-` prefix, and
line-number gutter match Claude Code's own diff rendering, while keeping
Casper's existing syntax-highlighted code text untouched.

**Architecture:** Two focused changes in `CasperUI`. `DiffLineStyle.swift` (the
pure, unit-testable color/logic layer) gets new tint and solid background colors
plus a new pure `lineNumber(for:)` helper that picks the single gutter number
for a diff line. `DiffSurfaceView.swift`'s private `DiffLineRow` consumes those
to collapse its two-column old/new gutter into one column and to tint both the
gutter number and the `+`/`-` prefix character.

**Tech Stack:** Swift 6 / SwiftUI, XCTest.

## Global Constraints

- Design source of truth: `.superpowers/plans/diff-view-claude-code-colors.md`
  (approved).
- Reference colors, sampled from the user-supplied screenshot: deletion
  background `#300B03`, addition background `#152606`, deletion tint `#B96A5E`,
  addition tint `#87C163`.
- Syntax highlighting on the code text (`DiffHighlighter`/HighlightSwift output)
  is untouched — only background, prefix, and line-number colors change.
- Dark-only: the app already forces `NSAppearance(named: .darkAqua)`
  (`Sources/CasperUI/AppDelegate.swift:23`); no light-mode variant is needed.
- All source edits go through the `skillbox:code-writer` agent, all reviews
  through `skillbox:code-reviewer`, per this project's standing
  `superpowers:subagent-driven-development` workflow — one commit per task.
- Tests need the full Xcode toolchain (`sudo xcode-select -s
  /Applications/Xcode.app`) — run via `swift test` or `make test`.

---

### Task 1: Update `DiffLineStyle` colors and add the single-gutter-number helper

**Files:**
- Modify: `Sources/CasperUI/DiffLineStyle.swift`
- Test: `Tests/CasperUITests/DiffLineStyleTests.swift`

**Interfaces:**
- Consumes: `CasperGit.GitDiffLine` (`kind: Kind`, `content: String`,
  `oldLineNumber: Int?`, `newLineNumber: Int?`), `GitDiffLine.Kind` (`.context`,
  `.addition`, `.deletion`) — both already defined in
  `Sources/CasperGit/Diff.swift:59-69`.
- Produces (consumed by Task 2):
  - `DiffLineStyle.insertionTint: Color`, `DiffLineStyle.deletionTint: Color`
    (existing names, new values).
  - `DiffLineStyle.background(for: GitDiffLine.Kind) -> Color` (existing
    signature, new values).
  - `DiffLineStyle.accent(for: GitDiffLine.Kind) -> Color` (unchanged
    signature/values — still derived from the tints).
  - `DiffLineStyle.lineNumber(for: GitDiffLine) -> Int?` (**new**).

- [ ] **Step 1: Write the failing tests**

`Tests/CasperUITests/DiffLineStyleTests.swift` currently starts with:

```swift
import CasperGit
import XCTest
@testable import CasperUI
```

Add `import SwiftUI` to that import block (needed for the `Color` values in the
new tests), so it reads:

```swift
import CasperGit
import SwiftUI
import XCTest
@testable import CasperUI
```

Then append these three test methods inside `DiffLineStyleTests`, after the
existing `testPrefix()`:

```swift
    func testTintsMatchClaudeCodeReference() {
        XCTAssertEqual(DiffLineStyle.insertionTint, Color(red: 0.529, green: 0.757, blue: 0.388))
        XCTAssertEqual(DiffLineStyle.deletionTint, Color(red: 0.725, green: 0.416, blue: 0.369))
    }

    func testBackgroundIsASolidSaturatedColor() {
        XCTAssertEqual(DiffLineStyle.background(for: .addition), Color(red: 0.082, green: 0.149, blue: 0.024))
        XCTAssertEqual(DiffLineStyle.background(for: .deletion), Color(red: 0.188, green: 0.043, blue: 0.012))
        XCTAssertEqual(DiffLineStyle.background(for: .context), Color.clear)
    }

    func testLineNumberPicksOldForDeletionAndNewForAdditionOrContext() {
        let deletion = GitDiffLine(kind: .deletion, content: "x", oldLineNumber: 30, newLineNumber: nil)
        let addition = GitDiffLine(kind: .addition, content: "x", oldLineNumber: nil, newLineNumber: 31)
        let context = GitDiffLine(kind: .context, content: "x", oldLineNumber: 5, newLineNumber: 5)

        XCTAssertEqual(DiffLineStyle.lineNumber(for: deletion), 30)
        XCTAssertEqual(DiffLineStyle.lineNumber(for: addition), 31)
        XCTAssertEqual(DiffLineStyle.lineNumber(for: context), 5)
    }
```

Note: this also requires `import SwiftUI` in the test file for the `Color` type
— check the top of `Tests/CasperUITests/DiffLineStyleTests.swift` and add it if
missing (it currently imports only `CasperGit` and `XCTest`).

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter CasperUITests.DiffLineStyleTests` Expected: FAIL —
`testTintsMatchClaudeCodeReference` and `testBackgroundIsASolidSaturatedColor`
fail on value mismatch (old colors),
`testLineNumberPicksOldForDeletionAndNewForAdditionOrContext` fails with
"lineNumber not found in scope" (compile error until Step 3).

- [ ] **Step 3: Update `Sources/CasperUI/DiffLineStyle.swift`**

Replace the whole file with:

```swift
import CasperGit
import SwiftUI

/// Pure mapping from a diff line kind to its rendering cues. Kept out of the
/// view so this (color-independent) logic is unit-testable and the view stays
/// declarative.
enum DiffLineStyle {
    /// Accent hues for the leading stripe, the +/- prefix, the gutter line
    /// number, and the +N -N stat badges. Sampled from Claude Code's own diff
    /// rendering so Casper's diff view reads the same way.
    static var insertionTint: Color { Color(red: 0.529, green: 0.757, blue: 0.388) }
    static var deletionTint: Color { Color(red: 0.725, green: 0.416, blue: 0.369) }

    static func prefix(for kind: GitDiffLine.Kind) -> String {
        switch kind {
        case .addition: return "+"
        case .deletion: return "-"
        case .context: return " "
        }
    }

    /// Solid, saturated row background — sampled from Claude Code's own diff
    /// rendering (not derived from the accent tint, which is too pale at any
    /// reasonable opacity to match). The app is dark-only
    /// (`AppDelegate.swift` forces `.darkAqua`), so there is no light-mode
    /// variant to maintain.
    static func background(for kind: GitDiffLine.Kind) -> Color {
        switch kind {
        case .addition: return Color(red: 0.082, green: 0.149, blue: 0.024)
        case .deletion: return Color(red: 0.188, green: 0.043, blue: 0.012)
        case .context: return Color.clear
        }
    }

    /// Solid leading accent stripe, also used to tint the +/- prefix and the
    /// gutter line number on changed lines.
    static func accent(for kind: GitDiffLine.Kind) -> Color {
        switch kind {
        case .addition: return insertionTint
        case .deletion: return deletionTint
        case .context: return Color.clear
        }
    }

    /// The single gutter line number for a diff line: the old (HEAD) line
    /// number for a deletion, the new (working-tree) line number for an
    /// addition or context line. Matches git's own line correspondence and
    /// collapses the gutter to one column, as in Claude Code's diff
    /// rendering, instead of two side-by-side old/new columns.
    static func lineNumber(for line: GitDiffLine) -> Int? {
        line.kind == .deletion ? line.oldLineNumber : line.newLineNumber
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter CasperUITests.DiffLineStyleTests` Expected: PASS (4
tests: the 3 new ones + the existing `testPrefix`)

- [ ] **Step 5: Commit**

```bash
git add Sources/CasperUI/DiffLineStyle.swift Tests/CasperUITests/DiffLineStyleTests.swift
git commit -m "Match diff row colors and gutter numbering to Claude Code"
```

---

### Task 2: Collapse the gutter to one column and tint the number and prefix

**Files:**
- Modify: `Sources/CasperUI/DiffSurfaceView.swift` (the private `DiffFileView`
  and `DiffLineRow` structs, roughly lines 202-410)

**Interfaces:**
- Consumes: `DiffLineStyle.lineNumber(for:)`, `DiffLineStyle.accent(for:)`,
  `DiffLineStyle.prefix(for:)`, `DiffLineStyle.background(for:)` (all from Task
  1).
- Produces: no new public interface — this is the leaf view.

This task has no new pure logic to drive with a unit test (it's SwiftUI
layout/rendering), so it's verified by build + manual check in the running app
rather than XCTest, per the existing pattern in this file (`DiffLineRow` has no
tests today either).

- [ ] **Step 1: Update `DiffFileView.gutterWidth`**

In `Sources/CasperUI/DiffSurfaceView.swift`, find:

```swift
    /// Two line numbers plus inter-number spacing, with a sensible minimum width.
    private var gutterWidth: CGFloat {
        max(CGFloat(maxDigits * 2 * 9 + 24), 60)
    }
```

Replace with:

```swift
    /// One line number plus trailing padding, with a sensible minimum width.
    private var gutterWidth: CGFloat {
        max(CGFloat(maxDigits * 9 + 12), 36)
    }
```

- [ ] **Step 2: Drop the now-unused `maxDigits` argument from the `DiffLineRow`
  call site**

Find (inside `DiffFileView.body`, in the `ForEach` over hunk lines):

```swift
                        ForEach(Array(entry.hunk.lines.prefix(entry.lineCount).enumerated()), id: \.offset) { _, line in
                            DiffLineRow(
                                line: line, gutterWidth: gutterWidth, contentWidth: contentWidth,
                                maxDigits: maxDigits, highlighted: highlightedLine(for: line))
                        }
```

Replace with:

```swift
                        ForEach(Array(entry.hunk.lines.prefix(entry.lineCount).enumerated()), id: \.offset) { _, line in
                            DiffLineRow(
                                line: line, gutterWidth: gutterWidth, contentWidth: contentWidth,
                                highlighted: highlightedLine(for: line))
                        }
```

- [ ] **Step 3: Rewrite `DiffLineRow`**

Find the whole `DiffLineRow` struct (from `private struct DiffLineRow: View {`
to its closing brace, currently the last struct in the file) and replace it
with:

```swift
private struct DiffLineRow: View {
    let line: GitDiffLine
    let gutterWidth: CGFloat
    let contentWidth: CGFloat
    let highlighted: AttributedString?

    var body: some View {
        HStack(spacing: 0) {
            // Leading accent stripe hugs the very left edge (clear for context).
            Rectangle()
                .fill(DiffLineStyle.accent(for: line.kind))
                .frame(width: 3)
            HStack(spacing: 8) {
                Text(DiffLineStyle.lineNumber(for: line).map(String.init) ?? "")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(numberColor)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(width: gutterWidth, alignment: .trailing)
                codeText
                    .font(.system(size: 14, design: .monospaced))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(minWidth: contentWidth, alignment: .leading)
        .background(DiffLineStyle.background(for: line.kind))
    }

    /// Context lines keep the neutral gray gutter; changed lines pick up the
    /// same accent as the stripe, matching Claude Code's tinted line numbers.
    private var numberColor: AnyShapeStyle {
        line.kind == .context ? AnyShapeStyle(.tertiary) : AnyShapeStyle(DiffLineStyle.accent(for: line.kind))
    }

    /// The code column. When a highlight is available its runs carry their own
    /// syntax colors (fonts stripped, so the monospaced font above applies
    /// uniformly); the prefixed diff marker is tinted with the line's accent
    /// color regardless of highlight availability. Falls back to plain text
    /// with a uniform `.primary` foreground for the code when there is no
    /// highlight.
    @ViewBuilder private var codeText: some View {
        if let highlightedContent {
            Text(highlightedContent)
        } else {
            Text(DiffLineStyle.prefix(for: line.kind)).foregroundStyle(DiffLineStyle.accent(for: line.kind))
                + Text(line.content).foregroundStyle(Color.primary)
        }
    }

    /// The diff marker prepended to the highlighted content, tinted with the
    /// line's accent color; the appended runs keep their syntax colors.
    private var highlightedContent: AttributedString? {
        guard let highlighted else { return nil }
        var prefix = AttributedString(DiffLineStyle.prefix(for: line.kind))
        prefix.foregroundColor = DiffLineStyle.accent(for: line.kind)
        prefix.append(highlighted)
        return prefix
    }
}
```

- [ ] **Step 4: Build**

Run: `swift build` Expected: builds cleanly, no warnings about unused
`maxDigits` in `DiffLineRow` (it was removed) and no type errors on the
`Text(...) + Text(...)` concatenation (SwiftUI supports `+` on `Text`) or on
`AttributedString.foregroundColor` (available via the `SwiftUI` import already
at the top of the file).

- [ ] **Step 5: Run the full test suite**

Run: `make test` Expected: PASS — no test exercises `DiffLineRow` directly, so
this is a regression check for `DiffLineStyleTests` and everything else.

- [ ] **Step 6: Manual verification**

Run: `make dev` In the launched app, open a workspace with a working-tree diff
that has additions, deletions, and context lines (e.g. edit a tracked file and
open its diff in the inspector). Confirm:
- Each row shows exactly one line-number column (not two).
- Deletion rows: solid dark maroon background, red-tinted line number, red `-`
  prefix, syntax-highlighted code text.
- Addition rows: solid dark olive-green background, green-tinted line number,
  green `+` prefix, syntax-highlighted code text.
- Context rows: unchanged — no background wash, gray line number, no accent
  stripe.
- The `+N`/`−N` badges in each file's header still render in the (now slightly
  different) insertion/deletion tint colors.

- [ ] **Step 7: Commit**

```bash
git add Sources/CasperUI/DiffSurfaceView.swift
git commit -m "Collapse diff gutter to one column and tint number/prefix"
```

---

## Final Review

After both tasks are committed, dispatch a final whole-branch
`skillbox:code-reviewer` pass over `Sources/CasperUI/DiffLineStyle.swift` and
`Sources/CasperUI/DiffSurfaceView.swift` before considering this plan done, per
this project's standing subagent-driven-development workflow.
