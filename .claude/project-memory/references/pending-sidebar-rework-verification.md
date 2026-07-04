---
name: "Pending: verify sidebar rework in the running app"
description: "Manual GUI check owed for the custom-sidebar rework committed in dba53d3"
type: project
---

# Pending: verify sidebar rework in the running app

The sidebar rework (commit `dba53d3`, 2026-07-04) is committed with green
build + tests but **without visual verification** — Ghostty surface creation
failed for the whole session (`ghostty_surface_new returned null`, the
[[e2e-surface-creation-flakiness]] case), so no screenshot could be taken.

**Why:** the change is UI-only (custom `ScrollView`/`LazyVStack` sidebar,
drawn selection pill, persisted `Space.isCollapsed`, add-folder footer, row
indent); its correctness is visual and was validated only against an HTML
mockup, not the real SwiftUI render.

**How to apply:** in a session where Ghostty surfaces initialize, use the
[[debug-casper]] skill to run a debug build and screenshot. Check: selected
workspace stays accent-highlighted while the terminal has focus; collapse
persists across relaunch and animates; the "Add folder…" footer works;
non-Git Spaces show the folder glyph; the row icon aligns under the Space
name; the "+" and notification bubbles share one trailing column. A
deterministic demo session generator lives in the session scratchpad
(`gen_session.py`), or add folders via the UI.
