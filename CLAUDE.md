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

Requires `brew install libgit2 pkgconf` (CasperGit links libgit2 via pkg-config).

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

Durable project context lives **in this repo** under [`docs/memory/`](docs/memory/),
one Markdown file per fact. There is **no external memory store** — do not read
or write `~/.claude/.../memory`; this section is the index and is loaded with
these instructions every session. Read the relevant entry when it applies. When
something durable emerges (a decision, a workflow preference, corrective
feedback, a hard-won reference detail), add or update a file in `docs/memory/`
and add a one-line pointer to the index below. Don't duplicate what the repo
already records (code, git history, the design spec).

Entries link each other with `[[slug]]` (the file's `name:`). Index:

- [project](docs/memory/project.md) — what Casper is, architecture, 5-plan roadmap, current status
- [dependency-policy](docs/memory/dependency-policy.md) — native-first, minimal deps; only GhosttyKit + swift-argument-parser + libgit2
- [libgit2-swift-interop](docs/memory/libgit2-swift-interop.md) — Clibgit2 gotchas: no variadic `_v`, pkg-config linking, pointer lifecycle
- [test-toolchain](docs/memory/test-toolchain.md) — XCTest needs full Xcode; how to build/test locally + gotchas
- [git-workflow](docs/memory/git-workflow.md) — get explicit authorization before git init/commit/push; commit identity
- [commit-message-style](docs/memory/commit-message-style.md) — verb + action performed, always in English
- [english-only](docs/memory/english-only.md) — all generated text (docs, code, UI) must be in English
- [swift6-network-concurrency](docs/memory/swift6-network-concurrency.md) — NWListener classes: `@unchecked Sendable` + serial-queue discipline
- [hooks-install-once](docs/memory/hooks-install-once.md) — `casper hooks setup` per worktree, not per terminal; `hooks feed` relays
- [casper-cli-availability](docs/memory/casper-cli-availability.md) — no global install/shim; reachable only in Casper terminals via PATH injection

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
