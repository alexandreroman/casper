---
name: "Address submit resigns first responder first"
description: "The browser address field ends editing before issuing the load: webView.url changes synchronously inside load(_:) and syncNav dedupes, so a write skipped mid-edit is never retried"
type: reference
---

# Address submit resigns first responder first

`control(_:textView:doCommandBy:)` in
`Sources/CasperUI/BrowserSurfaceView.swift` handles Return on the address field
by calling `control.window?.makeFirstResponder(nil)` **before**
`parent.onSubmit()`: end editing first, issue the load second. The order is
load-bearing, not stylistic.

**Why:** `webView.url` changes *synchronously inside* `webView.load(_:)` (see
[[webkit-page-driven-navigation]]), so the KVO-driven `syncNav` in
`Sources/CasperUI/BrowserCoordinator.swift` runs inside the submit call itself.
`syncNav` writes the canonical URL into `address` only while
`isEditingAddress` is false, and it deduplicates on its `NavigationState` — the
same url / canGoBack / canGoForward triple syncs exactly once. So a write
skipped because the field still holds first responder gets no second chance
from any later commit or finish, and the bar keeps the raw typed text
(`localhost:3000` where the committed URL is `http://localhost:3000/`).
Resigning first clears `isEditingAddress` — the field's focus change drives it
— in time for that one sync, so the bar shows the pending URL the moment the
load starts and converges on the committed one.

The submit path runs through an `NSControl` delegate rather than SwiftUI's
`onSubmit` because the address bar is a hand-owned `NSTextField`, per
[[browser-address-bar-select-all]].

**How to access:** to check the ordering by hand, type a host with no scheme
(`localhost:3000`) into the address bar and press Return — the bar must settle
on the normalized absolute URL, not the typed string.
