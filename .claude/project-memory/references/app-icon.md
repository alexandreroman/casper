---
name: "App icon design and generation pipeline"
description: "Casper's app icon is a full-bleed split-terminal mark; how it is authored, generated, and wired into the bundle"
type: project
---

# App icon design and generation pipeline

Casper's macOS app icon is a **full-bleed "split terminal"**: the rounded-square
icon *is* the terminal, split vertically down the middle — left pane a **cream
prompt caret `>`**, right pane an **amber 4-point sparkle** (the AI agent), on a
dark night-terminal gradient body. It is **inspired by Ghostty** (it reuses the
exact caret path from Ghostty's official logo, and Ghostty's cream foreground)
but is deliberately **not a ghost**.

Palette: body gradient `#15182F → #090B1B`, caret cream `#F6F1E2`, sparkle
gradient `#FFDD86 → #FF9E3D`, split line mint `#8EF7DE` at 0.20 opacity.

**Files & pipeline:**
- Master: `Packaging/AppIcon/icon.svg` (1024×1024; macOS template — 824×824
  content centered with 100 px padding, corner radius 186, baked soft drop
  shadow, transparent canvas).
- `Packaging/AppIcon/AppIcon.icns` is **committed** so ordinary builds need no
  rasterizer.
- Regenerate with **`make icon`** (→ `Scripts/make-icon.sh`), which rasterizes
  the 10 iconset sizes with **resvg** (`brew install resvg` — chosen over
  ImageMagick, whose SVG path ignores `feGaussianBlur`/gradients) then packs
  them with `iconutil`.
- Wired via `CFBundleIconFile` = `AppIcon` in **both** `Packaging/Info.plist`
  (release) and `Packaging/Info-dev.plist` (dev). The `.icns` is copied into
  `Contents/Resources/` by `Scripts/bundle-app.sh` (release bundle) and by the
  Makefile `build:` target (dev `Casper-dev.app`).

**Why:** the app had no icon; this gives it a native macOS one whose form
encodes Casper's essence — the split = per-worktree terminal workspaces, the
sparkle = the agent — with a Ghostty family resemblance (Casper embeds
libghostty).

**How to apply:** edit `icon.svg`, then run `make icon`; never hand-edit the
`.icns`. `iconutil` requires the iconset directory name to end in `.iconset`
(the script renders into `<tmp>/AppIcon.iconset`, not the bare `mktemp -d`).
See [[ghosttykit-pin]] and [[ghostty-is-the-reference]] for the Ghostty
relationship.
