# Casper

Native macOS app embedding libghostty to give each Git worktree its own
agent-aware terminal workspace.

See [README.md](README.md) for full documentation, and the design docs under
[`.superpowers/`](.superpowers/): design (`architecture.md` + `themes/`, the
authoritative source of truth for design), implementation progress
(`status.md`), and the map (`INDEX.md`). The `.superpowers/sdd/` scratch stays
out of Git.

## Tech stack

- Swift 6.2 / Swift Package Manager — needs **Xcode 26+** (`GhosttySurfaceView`
  uses a Swift 6.2 `@MainActor` isolated conformance; older compilers reject
  it). Targets **macOS 15+, arm64-only**.
- UI: SwiftUI + targeted AppKit. Browser: `WKWebView`. Notifications:
  `UserNotifications`. IPC: `Network.framework`.
- The only sanctioned external dependencies are **GhosttyKit** (libghostty),
  **swift-argument-parser**, **libgit2**, **HighlightSwift** (syntax
  highlighting for the diff view), and **Sparkle** (auto-update — see the note
  [`sparkle-eddsa-key.md`](.claude/project-memory/references/sparkle-eddsa-key.md)).
  Everything else uses built-in macOS frameworks. (`swiftui-introspect` was
  tried for the diff view's frozen file header but dropped — its
  `.introspect(.scrollView, on: .macOS(.v26))` closure fires unreliably on macOS
  26, a currently open upstream bug:
  https://github.com/siteline/swiftui-introspect/issues/465.)

## Build & run

Full prerequisites, the Make-target reference, the `make vendor` and
`dylibbundler` caveats, the dSYM story and the debug code-signing setup are all
in [README.md](README.md) § Building from source. The targets in daily use:

```bash
make build   # compile, then assemble + sign Casper-dev.app (assemble-bundle.sh
             #   debug, install_name_tool rpath, Info-dev.plist, codesign)
make dev     # rebuild + launch Casper-dev.app under a per-branch dev session
make test    # run the test suite
make release # size-optimized release build (arm64)
make bundle  # assemble a self-contained Casper.app (release binary + dylibs)
make dist    # package Casper.app into a .zip + .sha256 + dSYM.zip
make vendor  # re-sync Vendor/ghostty/ghostty.h (contributor-only; run AFTER a build)
make memory  # DEBUG only — watch a running dev instance for memory growth
casper       # (no args) launch the Casper app (SwiftUI GUI)
```

The app icon ships in two forms: the legacy `Packaging/AppIcon/AppIcon.icns`
(fallback for macOS 15–25, regenerated from `icon.svg` via `make icon` — which
also rebuilds `AppIconDev.icns` from `icon-dev.svg` — and needs
`brew install resvg`), and the macOS 26 Liquid Glass
`Packaging/AppIcon/AppIcon.icon` (Icon Composer bundle, compiled to `Assets.car`
by `actool` during `make bundle`). Both `CFBundleIconName` and
`CFBundleIconFile` are set. Compiling the `.icon` requires **Xcode 26** selected
(`sudo xcode-select -s /Applications/Xcode.app`). To re-author the layered icon:
edit the layer sources in `Packaging/AppIcon/AppIcon.icon/Assets/`, re-import
them into Icon Composer, and commit the updated `AppIcon.icon`.

## Modules

`.superpowers/architecture.md` § Modules is the authoritative table — module
boundaries, what each owns, and the theme doc that details it.

## Agents

Use the following agents (from the
[skillbox](https://github.com/alexandreroman/skillbox) plugin) for all code
tasks:

- **code-writer** — for ANY task that writes, modifies, or refactors code. This
  includes one-line fixes, import changes, visibility tweaks, and adding
  assertions. Never use the Edit or Write tools directly on source files —
  always delegate to this agent.
- **code-reviewer** — for read-only code review before merging or when
  investigating issues.

## Memory

**Always manage project memory with the `skillbox:project-memory` skill** — use
it to save durable context (decisions and their rationale, workflow preferences,
corrective feedback, external references) and to recall it. The skill defines
the frontmatter, tense, contradiction handling, and location. Read the index
[`.claude/project-memory/MEMORY.md`](.claude/project-memory/MEMORY.md) at the
start of work. Don't store what the repo already records (code, git history, the
`.superpowers/` design spec). Memory lives **only** here — not in
`.superpowers/` or `~/.claude`.

## Conventions

- Line length: Markdown 80 columns, code 120 columns. Standard Markdown spacing;
  fenced code blocks with a language tag.
- Prefer the latest stable versions of tools — **except GhosttyKit**, whose
  embedding API is unstable and must stay **pinned** (all access isolated in
  `CasperGhostty`).
- Tests use XCTest and need the **full Xcode toolchain**
  (`sudo xcode-select -s /Applications/Xcode.app`) — see the `test-toolchain`
  memory note for the CLT-can't-link-XCTest and `import Foundation` gotchas.
