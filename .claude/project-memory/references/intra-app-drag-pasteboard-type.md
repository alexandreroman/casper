---
name: "Intra-app drag pasteboard type"
description: "Pane drag-and-drop must transport over a standard pasteboard type; a code-only custom UTType is not matched by SwiftUI .onDrop"
type: reference
---

# Intra-app drag pasteboard type

Casper's pane drag-and-drop (relocating a split by dragging its grip) carries
the dragged `Surface.id` over the **standard** pasteboard type
`public.utf8-plain-text` (`NSPasteboard.PasteboardType.string` /
`UTType.utf8PlainText`), written by the AppKit drag source
(`PaneDragHandleView.beginDrag`) and read by the SwiftUI `PaneDropDelegate`. The
delegate filters foreign text drags by parsing the payload as a `UUID` (non-UUID
→ silent no-op). The relevant code is `Sources/CasperUI/PaneDragAndDrop.swift`.

**Why:** a custom `UTType(exportedAs: "com.casper.surface-id")` declared **only
in code** (even `conformingTo: .data`) is silently ignored by SwiftUI `.onDrop`
— the drop delegate is never engaged (`validateDrop` never fires), so no
highlight and no relocation. A code-declared type is not system-registered, so
SwiftUI's drop registration matches nothing; Ghostty avoids this because its
bundle declares the UTType in `Info.plist`. A standard, built-in pasteboard type
is always registered and matches reliably, and needs no declaration at all.

**How to access:** keep the transport on a standard type. `Casper.app` does
carry an `Info.plist` (`Packaging/Info.plist`, installed by
`Scripts/bundle-app.sh`), so a private `UTType` is technically reachable via
`UTExportedTypeDeclarations` — but it buys nothing over the standard type and
adds a registration dependency, so the standard type stands. Note also
(same file/spec): the drag SOURCE, the grip handle, and the drop-zone highlight
are all AppKit `NSView`s layered in the `ZStack` — a Metal-backed libghostty
surface composites **above** sibling SwiftUI views, so any drag overlay drawn in
SwiftUI is invisible and must be an `NSView`. See
[[persistent-nsview-host-sharing]].
