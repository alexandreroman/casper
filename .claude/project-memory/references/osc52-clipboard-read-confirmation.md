---
name: "OSC 52 clipboard reads are confirmed"
description: "OSC 52 reads are gated by a modal prompt, and completing a read request as confirmed bypasses libghostty's whole clipboard-read policy"
type: project
---

# OSC 52 clipboard reads are confirmed

An OSC 52 *read* — `printf '\033]52;c;?\007'` — asks the terminal for the
clipboard and gets the answer written back to the asking program's stdin.
`GhosttyClipboardRead` (`Sources/CasperGhostty/GhosttyClipboardRead.swift`)
gates it behind a modal confirmation, mirroring the write gate
([[osc52-clipboard-write-confirmation]]) in shape: the same
`approveUntrusted: @MainActor (String) -> Bool` seam, the same shared
`GhosttyClipboardPrompt.contentPreview`, the same Return-picks-Deny divergence
from upstream Ghostty.

**Why:** anything a Casper terminal prints can emit that sequence — a `cat`ed
file, an agent's output, a dependency's build script — and the answer goes
straight to whoever asked. An ungated read hands over whatever the user is
carrying: a password, a token, a private key.

**The flag that silently disables the whole policy.**
`ghostty_surface_complete_clipboard_request(surface, str, state, confirmed)`
takes a `confirmed` boolean that means *"the user has already approved this."*
Passing `true` from `read_clipboard_cb` short-circuits libghostty's
`clipboard-read` policy, so `confirm_read_clipboard_cb` never fires and no
prompt is ever raised, whatever that callback contains. `read_clipboard_cb`
therefore completes with `confirmed: false`, as upstream Ghostty does, and only
the confirmation path completes with `true`. The pinned reference header
(`Vendor/ghostty/ghostty.h`) documents none of this — the parameter is unnamed
and uncommented — so the behaviour rests on
`Tests/CasperGhosttyTests/GhosttyClipboardReadE2ETests.swift`, which drives a
real surface and a real shell and asserts that the gate is *consulted at all*.
That assertion is the one that fails under `confirmed: true`, when the grid
shows the clipboard arriving with no prompt. Unit tests cannot cover this: they
drive the `approveUntrusted` seam directly, so they stay green while the gate is
unreachable. The e2e test is `XCTSkip`-guarded per
[[e2e-surface-creation-flakiness]], and swaps
`GhosttyClipboardRead.systemPasteboard` so it never reads the developer's own
clipboard.

**Only OSC 52 reads prompt.** `confirm_read_clipboard_cb` also serves
`GHOSTTY_CLIPBOARD_REQUEST_PASTE`, which auto-confirms so an ordinary ⌘V never
prompts — including the multi-line paste that trips Ghostty's
`clipboard-paste-protection`. That protection is a separate, unimplemented
feature, not an oversight of this gate.

**A denied read still completes**, with an empty string, rather than being
dropped as upstream Ghostty drops it. An unresolved request leaves libghostty
holding pending state and the asking program blocked on stdin, which is the same
reasoning that already makes an unresolvable read complete with empty text.

**No `clipboard-read` config line is needed:** libghostty already defaults that
option to `ask`. This is the asymmetry with the write side, whose gate is
reachable only because Casper sets `clipboard-write = ask` itself.

**How to apply:** when touching either clipboard callback, check the `confirmed`
argument first — a gate that unit-tests green can still be unreachable in
production. Callback mechanics live in [[ghostty-clipboard-callbacks]].
