---
name: "Browser address bar select-all on click"
description: "Address field select-all is done in NSTextField.mouseDown after super, not on focus transition"
type: reference
---

# Browser address bar select-all on click

The browser address bar (`AddressField` / `SelectAllTextField` in
`Sources/CasperUI/BrowserSurfaceView.swift`) selects its whole text on a plain
click by overriding `NSTextField.mouseDown` and calling `selectAll` **after**
`super.mouseDown` returns, gated on `currentEditor()?.selectedRange.length == 0`.

**Why:** two non-obvious facts make the intuitive approaches fail, both
confirmed by instrumenting the running app:

- The field is **already first-responder** when the user clicks it — SwiftUI
  gives the `NSTextField` focus as soon as the inspector's Browser tab appears
  (`becomeFirstResponder` fires before any click). So any select-all keyed on
  the *focus transition* (SwiftUI `.focused` + `.onChange`, or the delegate's
  `controlTextDidBeginEditing`) never triggers on the user's click.
- Selecting *during* the mouse-down (in `controlTextDidBeginEditing`, even
  deferred with `DispatchQueue.main.async`) is racy: it can run before the
  click's own caret placement and gets collapsed. Only selecting **after
  `super.mouseDown` returns** (i.e. after the click's caret placement) is
  deterministic and sticks.

SwiftUI's `TextField` exposes no selection hook at all, which is why the address
bar is a hand-owned `NSViewRepresentable` over `NSTextField` — consistent with
[[ghostty-is-the-reference]] (own the AppKit control for native behavior).

**How to access:** the `selectedRange.length == 0` gate means a plain click
selects the whole URL while a click-drag or double-click that produced a real
selection is preserved. To verify select-all visually the `debug-casper` channel
is not enough (it can't target the address `NSTextField`); drive a **crisp**
synthetic click (mouse-down and mouse-up back-to-back — a gap lets the mouse-up
arrive after `super.mouseDown` returns and collapse the selection, a test-only
artifact) per [[gui-synthetic-input]], then screenshot and check the
highlight.
