# Casper

Native macOS app embedding libghostty to give each Git worktree its own
agent-aware terminal workspace.

See [README.md](README.md) for full documentation, and
[docs/superpowers/](docs/superpowers/) for the design spec and per-milestone
implementation plans (the authoritative source of truth).

## Tech stack

- Swift 6 / Swift Package Manager, targeting **macOS 14+, arm64-only**.
- UI: SwiftUI + targeted AppKit. Browser: `WKWebView`. Notifications:
  `UserNotifications`. IPC: `Network.framework`.
- The only sanctioned external dependencies are **GhosttyKit** (libghostty),
  **swift-argument-parser**, and **libgit2**. Everything else uses built-in
  macOS frameworks.

## Build & run

```bash
make build   # compile
make test    # run the test suite
make release # size-optimized release build (arm64)
```

## Modules

- **CasperCore** — models, session store, port allocator, hook parsing,
  agent-state reducer (pure Swift). *Implemented.*
- **CasperGit** — in-house libgit2 wrapper (worktrees, diff, status).
- **CasperGhostty** — embeds GhosttyKit; owns terminal surfaces and layout.
- **CasperAgents** — Claude Code adapter + hook `settings.json` generation.
- **CasperUI** — SwiftUI sidebar, chrome, diff, browser views.
- **CasperCLI** — `casper` subcommands. The app and CLI ship as one binary.

## Agents

Use the following agents (from the
[skillbox](https://github.com/alexandreroman/skillbox) plugin) for all code
tasks:

- **code-writer** — for ANY task that writes, modifies, or refactors code.
  This includes one-line fixes, import changes, visibility tweaks, and adding
  assertions. Never use the Edit or Write tools directly on source files —
  always delegate to this agent.
- **code-reviewer** — for read-only code review before merging or when
  investigating issues.

## Memory

Project decisions and durable context are persisted in Claude's built-in
persistent memory, which is loaded automatically at the start of each session
(via its `MEMORY.md` index). Record new project decisions, workflow
preferences, and corrective feedback there as they arise. Do not duplicate what
the repo already records (code, git history, the design spec).

## Conventions

- Line length: Markdown 80 columns, code 120 columns. Standard Markdown
  spacing; fenced code blocks with a language tag.
- Prefer the latest stable versions of tools — **except GhosttyKit**, whose
  embedding API is unstable and must stay **pinned** (all access isolated in
  `CasperGhostty`).
- Tests use XCTest and need the **full Xcode toolchain**
  (`sudo xcode-select -s /Applications/Xcode.app`); the Command Line Tools
  cannot link XCTest. XCTest files using Foundation types must
  `import Foundation` explicitly.
- Get explicit authorization before `git init`, committing, adding a remote,
  or pushing.
