# Project Memory

> When a new decision **contradicts** an existing memory note, do NOT silently
> override it. Instead: surface the conflict, quote the existing memory, explain
> how the new decision differs, and ask for explicit confirmation before
> updating. **Do NOT take any action** — no tool calls, no file writes — until
> confirmed.

- [Casper project](references/project.md) — what Casper is, architecture, 5-plan roadmap, current status
- [Dependency policy](references/dependency-policy.md) — native-first, minimal deps; only GhosttyKit + swift-argument-parser + libgit2
- [libgit2 Swift interop](references/libgit2-swift-interop.md) — Clibgit2 gotchas: no variadic `_v`, pkg-config linking, pointer lifecycle
- [Test toolchain](references/test-toolchain.md) — XCTest needs full Xcode; how to build/test locally + gotchas
- [Git workflow](references/git-workflow.md) — explicit authorization before git init/commit/push; commit identity
- [Commit message style](references/commit-message-style.md) — verb + action performed, always in English
- [English only](references/english-only.md) — all generated text (docs, code, UI) must be in English
- [Swift 6 Network concurrency](references/swift6-network-concurrency.md) — NWListener classes: `@unchecked Sendable` + serial-queue discipline
- [Hooks install once](references/hooks-install-once.md) — hooks installed once GLOBALLY (~/.claude/settings.json) via CLI or at app startup, not per worktree; `hooks feed` relays
- [casper CLI availability](references/casper-cli-availability.md) — no global install/shim; reachable only in Casper terminals via PATH injection
- [GhosttyKit / libghostty pin](references/ghosttykit-pin.md) — Lakr233/libghostty-spm 1.2.8 = Ghostty v1.3.1; GhosttyKit product only; vendored header via vendir
- [Debug channel and logging gating](references/debug-channel-gating.md) — debug control channel is `#if DEBUG` only, never in release; verbose logs gated, `.error`/`.fault` kept
- [Ghostty Metal layer contentsScale](references/ghostty-layer-contents-scale.md) — sync layer.contentsScale to window.backingScaleFactor or the render upscales ×2
- [Implementation workflow](references/implementation-workflow.md) — execute plans subagent-driven: one code-writer per task, review between, commit per task
