---
name: "Repeating animations are gated at the call site"
description: "A repeating SwiftUI animation driven by a one-shot @State flag must be mounted conditionally, not hidden by an internal branch"
type: project
---

# Repeating animations are gated at the call site

A SwiftUI view whose looping animation is driven by an `onAppear`-flipped
`@State` flag — the shape `.animation(loop, value: flag)` +
`.onAppear { flag = true }` — must be **mounted conditionally by its call
site**:

```swift
if workspace.pendingNotification {
    NotificationBubble(isSelected: isSelected)
}
```

Never by a condition the view carries as a property and branches on inside its
own `body`:

```swift
// Wrong: the struct is instantiated whatever `on` says.
NotificationBubble(on: workspace.pendingNotification, ...)
```

## Why

A property-gated view is still instantiated on every pass, so SwiftUI keeps its
`@State` storage alive across the gate going false and true again. The second
time round, `flag` is already `true`, `onAppear` re-assigns the same value, and
`.animation(_:value:)` sees no change — so it schedules nothing and the view
renders frozen at the animation's target values (`NotificationBubble` sat at
`opacity(0.5)`, `scaleEffect(1.3)`).

Mounting from the call site destroys the storage when the condition goes false,
so the next mount starts from `false` and the flip animates again.

## Where this applies

`WorkspaceRow`'s `NotificationBubble` (pending-notification dot) and
`SpinningIcon` (the `working` agent glyph) are both mounted this way. The same
rule covers any future breathing/spinning/pulsing indicator.
