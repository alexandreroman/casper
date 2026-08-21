---
name: "SwiftUI owns NSWindow.titleVisibility"
description: "Removing the window title in a SwiftUI app is done with .toolbar(removing: .title); an AppKit-level titleVisibility = .hidden loses the launch race and lags behind SwiftUI's own title writes"
type: feedback
---

# SwiftUI owns NSWindow.titleVisibility

Keep the window title out of the title bar with `.toolbar(removing: .title)`
(`ToolbarDefaultItemKind.title`, macOS 15+) on the root view. Setting
`window.titleVisibility = .hidden` from AppKit is at best a defensive fallback,
never the mechanism to rely on.

**Why:** SwiftUI writes `titleVisibility` itself — its `BarAppearanceBridge`
sets it from `AppKitWindowController.windowDidLoad` and again on every
`NSHostingView.preferencesDidChange` / view-graph update. An
`NSViewRepresentable` that hides the title from `makeNSView`'s
`DispatchQueue.main.async` hop runs ~0.8 s later, so the title is drawn for the
whole window-load-to-hop gap (a visible flash at launch). A re-show by a later
SwiftUI update then stays on screen until the next
`NSWindow.didUpdateNotification` — in practice until the user moves the mouse.
`.toolbar(removing: .title)` makes SwiftUI report `titleVisibility == .hidden`
from the very first frame, and it never flips back.

**How to apply:** attach the modifier to the outermost view that all branches go
through, so it covers every layout the window can host (empty state and
`NavigationSplitView` alike). `.navigationTitle` still sets the window's title
string — the modifier only removes its display in the title bar. The AppKit hide
may stay alongside it, documented as a fallback.
