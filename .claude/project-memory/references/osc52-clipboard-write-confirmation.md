---
name: "OSC 52 clipboard writes are confirmed"
description: "OSC 52 writes are gated by a modal prompt: the testability seam, the deferral mechanism, the Return-key divergence from Ghostty"
type: project
---

# OSC 52 clipboard writes are confirmed

`GhosttyClipboardWrite.apply`
(`Sources/CasperGhostty/GhosttyClipboardWrite.swift`) honours libghostty's
`confirm` flag on `write_clipboard_cb`: `confirm == false` (a user gesture such
as ⌘C) writes straight to the pasteboard, `confirm == true` (an OSC 52 escape in
the terminal's own output) writes only with the user's explicit approval.

**Why:** anything a Casper terminal prints — a `cat`ed file, an agent's output,
a dependency's build log — can emit OSC 52, so an ungated write lets untrusted
output replace whatever the user is carrying on the clipboard.

**The seam.** The decision goes through
`GhosttyClipboardWrite.approveUntrusted: @MainActor (String) -> Bool`, which
defaults to the `NSAlert` presenter. It exists because **`NSAlert` cannot run
under XCTest** — without the seam the gate has no testable behaviour at all.
Configurability is not the reason, so do not widen it into a policy knob.
`Tests/CasperGhosttyTests/GhosttyClipboardTests.swift` pins all three paths —
trusted, approved, denied — against a per-test uniquely named `NSPasteboard`, so
no test touches the developer's clipboard.

**The precondition that makes the gate reachable.** libghostty raises `confirm`
only when it is configured to: `clipboard-write` defaults to `allow`, under
which the callback is always trusted and every line of the gate is dead code.
Casper ships `clipboard-write = ask` in `GhosttyDefaultConfig.text`, which loads
before the user's own Ghostty config so a user can still opt back into upstream
behaviour. Unit tests cannot catch that line going missing — they drive the
`approveUntrusted` seam directly and never observe how libghostty is configured
— so `GhosttyClipboardTests.testDefaultConfigMakesLibghosttyAskBeforeAnUntrustedWrite`
pins the config text itself.

**Scope:** reads have a gate of their own, of the same shape —
[[osc52-clipboard-read-confirmation]].

**Which deferral mechanism.** The confirmation hops to the next main-queue turn
with `DispatchQueue.main.async`, deliberately not the `CFRunLoopPerformBlock`
route that [[main-queue-starved-by-modal-loops]] prescribes. The general rule
for a libghostty callback: when the hazard is re-entering libghostty mid-tick,
use the main queue, because it *guarantees* the block cannot run inside the
current tick — the same guarantee `casperGhosttyCloseSurface` rests on — whereas
a run-loop block only promises some later pass of the loop, which a nested loop
entered from within that tick already satisfies. Reserve `CFRunLoopPerformBlock`
for work that must run *while* a modal loop is up. Modal starvation is a benign
cost here specifically because nothing in libghostty blocks on
`write_clipboard_cb` — it returns `void` with no completion — so a prompt
waiting behind an alert already on screen is merely delayed, which is also where
it belongs.

**Upstream parity, with one exception.** Per [[ghostty-is-the-reference]], the
prompt takes its wording and framing verbatim from Ghostty
(`macos/Sources/Features/ClipboardConfirmation/`): the "An application is
attempting to write to the clipboard." message, the caution framing, the
read-only scrolling preview of the pending content, and the Deny/Allow labels.
**One divergence is deliberate:** upstream binds Return to *Allow*; Casper binds
Return to *Deny* and marks Allow destructive with no key equivalent, following
Casper's own HIG convention (`AppModel+Presentation`: the consequential button
is never the Return-key default). This prompt is raised by output the user never
asked for and can appear under their hands mid-typing, so aligning the key
equivalent with upstream would hand terminal output a one-keystroke clipboard
hijack.

**The prompt is app-modal**, an `NSAlert.runModal()` rather than a sheet on the
originating window: a sheet's asynchronous completion cannot satisfy a
synchronous `Bool` seam, and every other Casper dialog is `runModal`. A write
from a background workspace's pane therefore blocks the whole app, and Casper
does not activate itself to raise the prompt.

**How to apply:** keep the gate, the seam, and the config line intact when
touching clipboard writes. Callback mechanics live in
[[ghostty-clipboard-callbacks]].
