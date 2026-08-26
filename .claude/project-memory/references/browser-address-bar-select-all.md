---
name: "Browser address bar select-all on click"
description: "Address field select-all is done in NSTextField.mouseDown after super, not on focus transition"
type: reference
---

# Browser address bar select-all on click

`SelectAllTextField.mouseDown` in `Sources/CasperUI/BrowserSurfaceView.swift`
holds the rule and its rationale. What the code cannot show is why the
intuitive approaches fail — both facts below come from instrumenting the
running app:

- The field is **already first-responder** when the user clicks it — SwiftUI
  gives the `NSTextField` focus as soon as the inspector's Browser tab appears
  (`becomeFirstResponder` fires before any click). So any select-all keyed on
  the *focus transition* (SwiftUI `.focused` + `.onChange`, or the delegate's
  `controlTextDidBeginEditing`) never triggers on the user's click.
- Selecting *during* the mouse-down (in `controlTextDidBeginEditing`, even
  deferred with `DispatchQueue.main.async`) is racy: it can run before the
  click's own caret placement and gets collapsed.

**How to access:** to verify select-all visually the `debug-casper` channel is
not enough (it can't target the address `NSTextField`); drive a **crisp**
synthetic click (mouse-down and mouse-up back-to-back — a gap lets the mouse-up
arrive after `super.mouseDown` returns and collapse the selection, a test-only
artifact) per [[gui-synthetic-input]], then screenshot and check the highlight.

To check the *submit* ordering by hand — `doCommandBy` ends editing before
issuing the load, and the skipped `syncNav` write is never retried — type a
host with no scheme (`localhost:3000`) into the address bar and press Return.
The bar must settle on the normalized absolute URL, not the typed string. See
[[webkit-page-driven-navigation]] for why `webView.url` moves synchronously
inside `load(_:)`.
