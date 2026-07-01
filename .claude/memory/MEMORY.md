# Memory Index

Single project-memory store for Casper. One Markdown file per fact; entries
cross-link with `[[slug]]` (the file's `name:`).

- [project](project.md) — what Casper is, architecture, 5-plan roadmap, current status
- [dependency-policy](dependency-policy.md) — native-first, minimal deps; only GhosttyKit + swift-argument-parser + libgit2
- [libgit2-swift-interop](libgit2-swift-interop.md) — Clibgit2 gotchas: no variadic `_v`, pkg-config linking, pointer lifecycle
- [test-toolchain](test-toolchain.md) — XCTest needs full Xcode; how to build/test locally + gotchas
- [git-workflow](git-workflow.md) — get explicit authorization before git init/commit/push; commit identity
- [commit-message-style](commit-message-style.md) — verb + action performed, always in English
- [english-only](english-only.md) — all generated text (docs, code, UI) must be in English
- [swift6-network-concurrency](swift6-network-concurrency.md) — NWListener classes: `@unchecked Sendable` + serial-queue discipline
- [hooks-install-once](hooks-install-once.md) — `casper hooks setup` per worktree, not per terminal; `hooks feed` relays
- [casper-cli-availability](casper-cli-availability.md) — no global install/shim; reachable only in Casper terminals via PATH injection
