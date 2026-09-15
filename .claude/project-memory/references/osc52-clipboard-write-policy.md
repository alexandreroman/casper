---
name: "OSC 52 clipboard writes are unprompted"
description: "Untrusted OSC 52 clipboard writes reach the pasteboard with no confirmation: the deciding seam, the dormant prompt, the accepted risk"
type: project
---

# OSC 52 clipboard writes are unprompted

`GhosttyClipboardWrite.apply`
(`Sources/CasperGhostty/GhosttyClipboardWrite.swift`) puts every write on the
pasteboard. libghostty's `confirm` flag on `write_clipboard_cb` tells a user
gesture such as ⌘C (`false`) apart from an OSC 52 escape in the terminal's own
output (`true`), and both land, because the policy the gate consults —
`GhosttyClipboardWrite.approveUntrusted`, a `@MainActor (String) -> Bool` —
approves unconditionally.

**Why:** a Casper workspace is built around agents driving the terminal, and OSC
52 is how a program inside one syncs the clipboard, so gating untrusted writes
interrupts ordinary work instead of catching something the user did not set in
motion. The risk is accepted with open eyes: anything a Casper terminal prints —
a `cat`ed file, an agent's output, a dependency's build log — can replace
whatever the user is carrying on the clipboard. The unconditional approval is a
deliberate decision, not an oversight, so leave it in place.

**The prompt is dormant, complete, and one line from active.**
`presentConfirmation` and the shared `GhosttyClipboardPrompt` (`confirm`,
`contentPreview`) compile and carry Ghostty's own framing verbatim
(`macos/Sources/Features/ClipboardConfirmation/`): the "An application is
attempting to write to the clipboard." message, the caution style, the read-only
scrolling preview of the pending content, and the Deny/Allow labels. Assigning
`presentConfirmation` to `approveUntrusted` is the whole of what asking the user
would take; both clipboard files' doc comments say as much.

**One divergence from upstream inside that dormant prompt:** upstream binds
Return to *Allow*; Casper binds Return to *Deny* and marks Allow destructive
with no key equivalent, following Casper's own HIG convention
(`AppModel+Presentation`: the consequential button is never the Return-key
default). A prompt raised by output the user never asked for can appear under
their hands mid-typing, so upstream's key equivalent would hand terminal output
a one-keystroke clipboard hijack.

**The seam is for tests, not for configuration.** `approveUntrusted` is a
substitutable property because **`NSAlert` cannot run under XCTest** — without
it the gate has no testable behaviour at all. Configurability is not the reason,
so do not widen it into a policy knob.
`Tests/CasperGhosttyTests/GhosttyClipboardTests.swift` drives it directly to pin
all three paths — trusted, approved, denied — against a per-test uniquely named
`NSPasteboard`, so no test touches the developer's clipboard. Those tests pass
whatever the production default is.

**`clipboard-write = ask` belongs in `GhosttyDefaultConfig.text`.** libghostty
defaults that option to `allow`, under which the callback is always trusted and
`apply`'s untrusted branch is unreachable. `ask` makes libghostty raise
`confirm`, which keeps `approveUntrusted` the single place the write policy is
decided rather than dead code.
`GhosttyClipboardTests.testDefaultConfigMakesLibghosttyAskBeforeAnUntrustedWrite`
pins the line, and the config loads before the user's own Ghostty config so a
user setting still overrides it.

**Which deferral mechanism the prompt path uses.** It hops to the next
main-queue turn with `DispatchQueue.main.async`, deliberately not the
`CFRunLoopPerformBlock` route that [[main-run-loop-hop]] prescribes. The general
rule for a libghostty callback: when the hazard is re-entering libghostty
mid-tick, use the main queue, because it *guarantees* the block cannot run
inside the current tick — the same guarantee `casperGhosttyCloseSurface` rests
on — whereas a run-loop block only promises some later pass of the loop, which a
nested loop entered from within that tick already satisfies. Reserve
`CFRunLoopPerformBlock` for work that must run *while* a modal loop is up. Modal
starvation is a benign cost here specifically because nothing in libghostty
blocks on `write_clipboard_cb` — it returns `void` with no completion.

**Scope:** reads have a policy of their own, of the same shape —
[[osc52-clipboard-read-policy]].

**How to apply:** keep `approveUntrusted` approving unconditionally, keep the
prompt code and the config line intact, and keep the seam test-only. Callback
mechanics live in [[ghostty-clipboard-callbacks]].
