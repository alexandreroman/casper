---
name: "Intra-app drag pasteboard type"
description: "Pane drag-and-drop must transport over a standard pasteboard type; a code-only custom UTType is not matched by SwiftUI .onDrop"
type: reference
---

# Intra-app drag pasteboard type

Casper's pane drag-and-drop (relocating a split by dragging its grip) carries the
dragged `Surface.id` over the **standard** pasteboard type `public.utf8-plain-text`
(`NSPasteboard.PasteboardType.string` / `UTType.utf8PlainText`), written by the
AppKit drag source (`PaneDragHandleView.beginDrag`) and read by the SwiftUI
`PaneDropDelegate`. The delegate filters foreign text drags by parsing the payload
as a `UUID` (non-UUID → silent no-op). The relevant code is
`Sources/CasperUI/PaneDragAndDrop.swift`.

**Why:** a custom `UTType(exportedAs: "com.casper.surface-id")` declared **only in
code** (even `conformingTo: .data`) is silently ignored by SwiftUI `.onDrop` — the
drop delegate is never engaged (`validateDrop` never fires), so no highlight and no
relocation. Casper is a bare SwiftPM executable with **no `Info.plist`**, so the
exported type is not system-registered, and SwiftUI's drop registration matches
nothing. Ghostty avoids this only because its app bundle declares the UTType in
`Info.plist`; Casper cannot without adding bundle packaging. A standard, built-in
pasteboard type is always registered and matches reliably.

**How to access:** keep the transport on a standard type as long as Casper ships as
a plain SwiftPM executable. Only reintroduce a private `UTType` if the app gains a
real bundle with `UTExportedTypeDeclarations`. Note also (same file/spec): the drag
SOURCE, the grip handle, and the drop-zone highlight are all AppKit `NSView`s
layered in the `ZStack` — a Metal-backed libghostty surface composites **above**
sibling SwiftUI views, so any drag overlay drawn in SwiftUI is invisible and must be
an `NSView`. See the design at
`docs/superpowers/specs/2026-07-04-split-drag-and-drop-design.md` and
[[persistent-nsview-host-sharing]].
