---
name: "App icon design and generation pipeline"
description: "Casper's app icon is a full-bleed split-terminal mark; how it is authored, generated, and wired into the bundle (legacy .icns + macOS 26 Icon Composer .icon)"
type: project
---

# App icon design and generation pipeline

Casper's macOS app icon is a **full-bleed "split terminal"**: the rounded-square
icon *is* the terminal, split vertically down the middle — left pane a **cream
prompt caret `>`**, right pane an **amber 4-point sparkle** (the AI agent), on a
neutral dark-gray gradient body matching the Visual Studio Code app icon
background. It is **inspired by Ghostty** (it reuses the exact caret path from
Ghostty's official logo, and Ghostty's cream foreground) but is deliberately
**not a ghost**.

Palette: body gradient `#3C3C3C → #1E1E1E` (VS Code neutral dark gray), caret
cream `#F6F1E2`, sparkle gradient `#FFDD86 → #FF9E3D`, split line mint `#8EF7DE`
at 0.20 opacity.

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
  (`Packaging/Info-dev.plist`) sets it = `AppIconDev`. Both bundles are staged
  by `Scripts/assemble-bundle.sh`, which picks the matching `.icns` from its
  release/debug argument; `Scripts/bundle-app.sh` adds only `Assets.car` on top
  of that staging.

**macOS 26 Liquid Glass icon (additive, release only):** alongside the legacy
`.icns`, the release build also ships an **Icon Composer** layered icon so macOS
26 (Tahoe) renders Default/Dark/Clear appearances. It is **additive**, not a
replacement — both `CFBundleIconName` (new, macOS 26) and `CFBundleIconFile`
(legacy, macOS 15–25) are set in `Packaging/Info.plist`, both = `AppIcon`. The
`.icns` stays the mandatory pre-Tahoe fallback; the split-icon workaround is NOT
used (Apple dropped support for it in Xcode 26.1).
- Source: `Packaging/AppIcon/AppIcon.icon` (Icon Composer bundle: `icon.json` +
  `Assets/`), **GUI-authored and committed** — the `icon.json` schema is
  undocumented and shifts across Xcode 26.x, so scripting it was rejected.
  Background = the body gradient set as a fill in the GUI; two foreground layers
  = the terminal marks (`Assets/terminal.svg`) and the sparkle
  (`Assets/sparkle.svg`).
- The layer sources live in `Packaging/AppIcon/AppIcon.icon/Assets/`, the single
  place they are authored: Icon Composer imports SVG directly — no PNG
  rasterization step — and writes the layers back there byte-identical.
- `Scripts/bundle-app.sh` compiles `AppIcon.icon` with **`xcrun actool`** (Xcode
  26 required) into `Contents/Resources/Assets.car`. It compiles into a **temp
  dir and copies only `Assets.car`** — actool also emits its own low-res
  `AppIcon.icns`, which would otherwise clobber the hand-crafted high-res one.
  The step no-ops (icns-only) when `AppIcon.icon` is absent.
- Dev build stays `.icns`-only (no `.icon`).

**Why:** the app had no icon; this gives it a native macOS one whose form
encodes Casper's essence — the split = per-worktree terminal workspaces, the
sparkle = the agent — with a Ghostty family resemblance (Casper embeds
libghostty). The Liquid Glass variant keeps the icon current on macOS 26 without
dropping older-OS support.

**Authoring the Liquid Glass icon** is a manual, one-time step Icon Composer
owns and nothing automates: create the icon, set the background to the dark
gradient (`#3C3C3C` top → `#1E1E1E` bottom), import `Assets/terminal.svg` and
`Assets/sparkle.svg` as two foreground layers, tune their material (specular /
glass) with a glow on the sparkle, then tune the **Dark** appearance (darker
body, brighter sparkle) and check **Clear** — the sparkle silhouette has to read
as monochrome. Save the whole package (`icon.json` + `Assets/`) to
`Packaging/AppIcon/AppIcon.icon` and commit it. Treat `icon.json`'s schema as
undocumented and version-sensitive: re-author through Icon Composer rather than
editing it by hand.

**How to apply:** for the `.icns`, edit `icon.svg`, then run `make icon`, which
rebuilds **both** `AppIcon.icns` (from `icon.svg`) and `AppIconDev.icns` (from
`icon-dev.svg`); never hand-edit an `.icns`. `iconutil` requires the iconset
directory name to end in
`.iconset` (the script renders into `<tmp>/AppIcon.iconset`, not the bare
`mktemp -d`). For the Liquid Glass icon, edit `AppIcon.icon/Assets/*.svg`,
re-import them into Icon Composer, and commit the updated `AppIcon.icon`; verify
with `assetutil --info` on the compiled `Assets.car` and `plutil` on the
bundle's `Info.plist`. See [[ghosttykit-pin]] and [[ghostty-is-the-reference]]
for the Ghostty relationship, and [[test-toolchain]] for the Xcode requirement.
