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
  highlighting for the diff view), and **Sparkle** (auto-update — see the plan
  [`sparkle-eddsa-key.md`](.claude/project-memory/references/sparkle-eddsa-key.md)).
  Everything else uses built-in macOS frameworks. (`swiftui-introspect` was
  tried for the diff view's frozen file header but dropped — its
  `.introspect(.scrollView, on: .macOS(.v26))` closure fires unreliably on macOS
  26, a currently open upstream bug:
  https://github.com/siteline/swiftui-introspect/issues/465.)

## Build & run

Requires `brew install libgit2 pkgconf` (CasperGit links libgit2 via
pkg-config). The first build downloads the ~53 MB `GhosttyKit.xcframework` from
the pinned `libghostty-spm` release; later builds reuse the extracted
artifact.

```bash
make build   # compile
make dev     # rebuild + launch Casper-dev.app under a per-branch dev session
make test    # run the test suite
make release # size-optimized release build (arm64)
make bundle  # assemble a self-contained Casper.app (release binary + bundled dylibs)
make dist    # package Casper.app into a .zip + .sha256 + dSYM.zip (release artifacts)
make vendor  # re-sync Vendor/ghostty/ghostty.h (contributor-only; run AFTER a build)
casper       # (no args) launch the Casper app (SwiftUI GUI)
```

`make vendor` is not part of building. It needs `brew install vendir` and
re-syncs the reference-only `Vendor/ghostty/ghostty.h` **out of the
already-extracted** `GhosttyKit.xcframework`, so it only works once a build has
downloaded that artifact, and is only worth running when the GhosttyKit pin
moves. No target compiles against the vendored header.

`make bundle`/`make dist` need `brew install dylibbundler` (embeds the libgit2
dylib chain into the bundle so the app runs on a clean Mac). The
`.github/workflows/release.yml` workflow runs `make dist` on every `v*` tag and
publishes the `.app` as a GitHub Release.

The release build compiles with `-Osize`, and `make bundle` extracts the debug
symbols to `Casper.dSYM` (kept **outside** `Casper.app`) before stripping the
shipped executable. `make dist` publishes that dSYM as a separate `.dSYM.zip`
asset so release crash reports stay symbolicatable.

The app icon ships in two forms: the legacy `Packaging/AppIcon/AppIcon.icns`
(fallback for macOS 15–25, regenerated from `icon.svg` via `make icon` — which
also rebuilds `AppIconDev.icns` from `icon-dev.svg` — and needs
`brew install resvg`), and the macOS 26 Liquid Glass
`Packaging/AppIcon/AppIcon.icon` (Icon Composer bundle, compiled to `Assets.car`
by `actool` during `make bundle`). Both `CFBundleIconName` and
`CFBundleIconFile` are set. Compiling the `.icon` requires **Xcode 26** selected
(`sudo xcode-select -s /Applications/Xcode.app`). To re-author the layered icon:
edit the layer sources `Packaging/AppIcon/layers/*.svg`, re-import them into
Icon Composer, and commit the updated `AppIcon.icon`.

## Modules

- **CasperCore** — models, session store, worktree manager, port allocator,
  control-channel protocol + socket (pure Swift).
- **CasperGit** — in-house libgit2 wrapper (worktrees, diff, status).
- **CasperGhostty** — embeds GhosttyKit; owns terminal surfaces and layout.
- **CasperAgents** — per-surface environment injection for Casper terminals.
- **CasperUI** — SwiftUI sidebar, chrome, diff, browser views.
- **CasperCLI** — `casper` subcommands. The app and CLI ship as one binary.

Two C shim targets sit under CasperGit: **Clibgit2** (the system-library module
map for libgit2) and **CSigbusGuard** (the SIGBUS guard around libgit2 diff).

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
