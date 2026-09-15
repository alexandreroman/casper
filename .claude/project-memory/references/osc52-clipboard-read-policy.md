---
name: "OSC 52 clipboard reads are unprompted"
description: "Untrusted OSC 52 clipboard reads are answered with no confirmation, and the `confirmed` flag silently disables libghostty's whole read policy"
type: project
---

# OSC 52 clipboard reads are unprompted

An OSC 52 *read* — `printf '\033]52;c;?\007'` — asks the terminal for the
clipboard and gets the answer written back to the asking program's stdin.
`GhosttyClipboardRead.resolveUntrusted`
(`Sources/CasperGhostty/GhosttyClipboardRead.swift`) answers it with the
clipboard text, because `GhosttyClipboardRead.approveUntrusted` approves
unconditionally. It mirrors the write policy ([[osc52-clipboard-write-policy]])
in shape: the same `approveUntrusted: @MainActor (String) -> Bool` seam, the
same dormant `GhosttyClipboardPrompt`, the same Return-picks-Deny divergence
from upstream Ghostty inside that dormant prompt.

**Why:** the write side's reasoning applies unchanged — agents drive a Casper
terminal and OSC 52 is how a program in one reaches the clipboard, so gating
reads interrupts ordinary work. The risk is accepted with open eyes: the answer
goes straight to whoever asked, so anything a Casper terminal prints can be
handed whatever the user is carrying — a password, a token, a private key. The
unconditional approval is a deliberate decision, not an oversight, so leave it
in place.

**The flag that silently disables the whole policy**, which matters whatever the
approval default is. `ghostty_surface_complete_clipboard_request(surface, str,
state, confirmed)` takes a `confirmed` boolean meaning *"the user has already
approved this."* Passing `true` from `read_clipboard_cb` short-circuits
libghostty's `clipboard-read` policy, so `confirm_read_clipboard_cb` never fires
and `GhosttyClipboardRead` is never consulted at all. `read_clipboard_cb`
therefore completes with `confirmed: false`, as upstream Ghostty does, and only
the confirmation path completes with `true`. Keeping that callback reachable is
what makes `approveUntrusted` the one place the read policy is decided rather
than dead code. The pinned reference header (`Vendor/ghostty/ghostty.h`)
documents none of this — the parameter is unnamed and uncommented — so the
behaviour rests on
`Tests/CasperGhosttyTests/GhosttyClipboardReadE2ETests.swift`, which drives a
real surface and a real shell and asserts that the gate is *consulted at all*.
Unit tests cannot cover it: they drive the `approveUntrusted` seam directly, so
they stay green while the gate is unreachable. The e2e test is `XCTSkip`-guarded
per [[e2e-surface-creation-flakiness]], and swaps
`GhosttyClipboardRead.systemPasteboard` so it never reads the developer's own
clipboard.

**No `clipboard-read` config line is needed:** libghostty already defaults that
option to `ask`, which routes the read through `confirm_read_clipboard_cb`. This
is the asymmetry with the write side, whose callback is flagged untrusted only
because Casper sets `clipboard-write = ask` itself.

**Only OSC 52 reads reach this policy.** `confirm_read_clipboard_cb` also serves
`GHOSTTY_CLIPBOARD_REQUEST_PASTE`, which auto-confirms, so an ordinary ⌘V takes
its own path — including the multi-line paste that trips Ghostty's
`clipboard-paste-protection`. That protection is a separate, unimplemented
feature.

**A denied read still completes**, with an empty string, rather than being
dropped as upstream Ghostty drops it — the path a substituted `approveUntrusted`
exercises. An unresolved request leaves libghostty holding pending state and the
asking program blocked on stdin, which is the same reasoning that already makes
an unresolvable read complete with empty text.

**How to apply:** keep `approveUntrusted` approving unconditionally, and check
the `confirmed` argument first when touching either clipboard callback — a gate
that unit-tests green can still be unreachable in production. Callback mechanics
live in [[ghostty-clipboard-callbacks]].
