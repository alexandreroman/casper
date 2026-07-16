---
name: "App icon design and generation pipeline"
description: "Casper's app icon is a full-bleed split-terminal mark; how it is authored, generated, and wired into the bundle"
type: project
---

# App icon design and generation pipeline

Casper's macOS app icon is a **full-bleed "split terminal"**: the rounded-square
icon *is* the terminal, split vertically down the middle — left pane a **cream
prompt caret `>`**, right pane an **amber 4-point sparkle** (the AI agent), on a
neutral dark-gray gradient body matching the Visual Studio Code app icon
background. It is **inspired by Ghostty** (it reuses the
exact caret path from Ghostty's official logo, and Ghostty's cream foreground)
but is deliberately **not a ghost**.

Palette: body gradient `#3C3C3C → #1E1E1E` (VS Code neutral dark gray), caret
cream `#F6F1E2`, sparkle
gradient `#FFDD86 → #FF9E3D`, split line mint `#8EF7DE` at 0.20 opacity.

There are **two variants**: the production icon and a **dev** variant that adds
a violet "DEV" corner ribbon (bottom-right), used only by `make dev` /
`Casper-dev.app` so the dev build is distinguishable in the Dock.

**Files & pipeline:**
- Masters: `Packaging/AppIcon/icon.svg` (prod) and
  `Packaging/AppIcon/icon-dev.svg` (dev = prod + violet `#6C5CE7` corner ribbon
  with "DEV" in Menlo bold, clipped to the icon shape). Both are 1024×1024,
  macOS template — 824×824 content centered with 100 px padding, corner radius
  186, baked soft drop shadow, transparent canvas.
- `Packaging/AppIcon/AppIcon.icns` and `Packaging/AppIcon/AppIconDev.icns` are
  **committed** so ordinary builds need no rasterizer.
- Regenerate BOTH with **`make icon`** (→ `Scripts/make-icon.sh`), which
  rasterizes the 10 iconset sizes per SVG with **resvg** (`brew install resvg` —
  chosen over ImageMagick, whose SVG path ignores `feGaussianBlur`/gradients and
  which cannot render the `<text>` label) then packs them with `iconutil`.
- Release (`Packaging/Info.plist`) sets `CFBundleIconFile` = `AppIcon`; dev
  (`Packaging/Info-dev.plist`) sets it = `AppIconDev`. `Scripts/bundle-app.sh`
  copies `AppIcon.icns` into the release bundle Resources; the Makefile `build:`
  target copies `AppIconDev.icns` into the dev bundle Resources.

**Why:** the app had no icon; this gives it a native macOS one whose form
encodes Casper's essence — the split = per-worktree terminal workspaces, the
sparkle = the agent — with a Ghostty family resemblance (Casper embeds
libghostty).

**How to apply:** edit `icon.svg`, then run `make icon`; never hand-edit the
`.icns`. `iconutil` requires the iconset directory name to end in `.iconset`
(the script renders into `<tmp>/AppIcon.iconset`, not the bare `mktemp -d`).
See [[ghosttykit-pin]] and [[ghostty-is-the-reference]] for the Ghostty
relationship.
