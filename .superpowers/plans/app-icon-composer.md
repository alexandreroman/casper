# Icon Composer migration — design

**Date:** 2026-07-17 **Status:** Shipped

Give Casper a macOS 26 (Tahoe) Liquid Glass app icon with all three appearances
(Default / Dark / Clear), while keeping the existing high-resolution `.icns` as
the fallback for macOS 15–25. The change is **purely additive**: the SVG→`.icns`
pipeline and the dev-build icon are left untouched.

## Background

macOS renders the app icon at the Finder/Dock from the bundle, not from the
in-app asset system. Two mechanisms exist:

- **Legacy** — `CFBundleIconFile` points at a `.icns` in `Contents/Resources/`.
  This is what Casper uses today (`AppIcon.icns`, generated from `icon.svg` by
  `Scripts/make-icon.sh`). Every macOS version understands it. `.icns` carries a
  single appearance — it cannot express Light/Dark/Tinted variants.
- **Liquid Glass (macOS 26+)** — `CFBundleIconName` names an icon baked into a
  compiled `Assets.car`. The source is an Icon Composer `.icon` bundle (layered
  art + material properties), from which the system derives the Default, Dark,
  and Clear (system-tinted, monochrome) appearances at runtime.

macOS 15–25 ignore `CFBundleIconName`/`Assets.car` entirely; macOS 26 prefers
`CFBundleIconName` when present. Shipping **both** keys and **both** files is
the supported way to serve old and new systems. The previously-circulated
"split-icon" workaround (separate icons for Tahoe vs. earlier via
`--enable-icon-stack-fallback-generation=disabled`) is **not used** — Apple
dropped support for it for Mac apps as of Xcode 26.1.

Authoring a `.icon` is effectively GUI-only (Icon Composer.app / Xcode 26): the
`icon.json` schema is undocumented and shifts across Xcode 26.x releases, so it
is authored once by hand in the GUI and committed, rather than scripted.

## Scope

**In scope**

- A committed `Packaging/AppIcon/AppIcon.icon` (Icon Composer bundle), authored
  once in the GUI, with Default / Dark / Clear appearances.
- Layer art extracted from the existing `icon.svg` to seed that GUI session.
- An `actool` compile step in the release bundling that produces
  `Contents/Resources/Assets.car`.
- `CFBundleIconName` added to the release `Info.plist` (alongside the retained
  `CFBundleIconFile`).
- A Makefile toolchain guard (no new target; the `layers/*.svg` sources import
  directly into Icon Composer).
- Documentation of the one-time manual authoring step, plus a project-memory
  note recording the decision.

**Out of scope (YAGNI)**

- Layered treatment for the dev build — `Casper-dev.app` keeps its current
  `AppIconDev.icns` only.
- Scripting `icon.json` (Approach B, rejected: fragile, undocumented schema,
  unreliable Liquid Glass materials).
- Notarization / App Store changes.

## Prerequisites

- macOS 26 (Tahoe) and Xcode 26 selected via `xcode-select`. Confirmed present
  on the dev machine (macOS 26.5.2, Xcode 26.6, `actool` resolves). This matches
  the project's existing "tests need the full Xcode toolchain" requirement.

## Repo layout

```text
Packaging/AppIcon/
  icon.svg, icon-dev.svg        # unchanged (SVG masters)
  AppIcon.icns, AppIconDev.icns # unchanged (fallback, committed)
  layers/                       # NEW — layer sources (committed + imported)
    terminal.svg                #   split line + cream caret (committed source)
    sparkle.svg                 #   orange sparkle, no glow filter (committed source)
  AppIcon.icon/                 # NEW — committed Icon Composer bundle (icon.json + Assets/)
```

The bundle is named `AppIcon.icon` so `actool --app-icon AppIcon` sets
`CFBundleIconName = AppIcon`, matching the existing `AppIcon.icns` /
`CFBundleIconFile = AppIcon`. One name, two mechanisms — no conflict, since they
resolve against different stores (a `.car` entry vs. a Resources file).

`icon.svg` composites four elements: the dark rounded body (`#3C3C3C→#1E1E1E`),
a teal vertical split line, a cream Ghostty prompt caret, and an orange sparkle
(`#FFDD86→#FF9E3D`) under a Gaussian-blur glow filter. These map to Icon
Composer as:

- **Background** — the dark body, expressed as a **gradient fill set in the
  GUI** (resolution-independent, no `background.png`; Icon Composer applies its
  own rounded-rect mask, so the body's own `rx`/drop-shadow are dropped).
- **Foreground layer 1 — terminal marks**: the split line + caret
  (`terminal.svg`), imported directly into Icon Composer.
- **Foreground layer 2 — sparkle**: the orange sparkle (`sparkle.svg`), imported
  directly and rendered *without* the SVG glow filter so the glow is reproduced
  as an Icon Composer material/specular effect on the layer.

Two foreground layers in one group, well within the four-group limit. Icon
Composer embeds the imported SVGs, byte-identical, in `AppIcon.icon/Assets/` —
there is no PNG rasterization step.

## Build pipeline changes

### `Scripts/bundle-app.sh`

Immediately after the existing `AppIcon.icns` copy (currently line 38), compile
the `.icon` into the bundle's Resources directory, before the ad-hoc signing
step (lines ~65–66):

```bash
# CFBundleIconName (Info.plist) resolves the layered icon from Assets.car on
# macOS 26+; older macOS falls back to CFBundleIconFile → AppIcon.icns above.
xcrun actool "$ROOT/Packaging/AppIcon/AppIcon.icon" \
    --compile "$APP/Contents/Resources" \
    --app-icon AppIcon --include-all-app-icons \
    --output-partial-info-plist "$TMP/actool-partial.plist" \
    --platform macosx --target-device mac \
    --minimum-deployment-target 15.0 \
    --errors --warnings --notices --output-format human-readable-text
```

- Emits `Contents/Resources/Assets.car`. The partial Info.plist is disposable
  for a Mac target and discarded. `bundle-app.sh` has no temp dir today, so the
  implementation adds one (`TMP="$(mktemp -d)"` with a `trap … EXIT` cleanup, as
  in `make-icon.sh`) for `$TMP/actool-partial.plist`.
- Runs before signing so `Assets.car` is in place first. (The current script
  ad-hoc-signs only the dylibs + main executable, not a deep bundle seal, so the
  icon resources are not sealed today; correct ordering is insurance for if deep
  signing is added later.)
- `actool` must come from Xcode 26. `bundle-app.sh` runs under the Makefile
  guard (below); it invokes `xcrun actool` so the selected toolchain is used.

### `Packaging/Info.plist`

Add, keeping the existing `CFBundleIconFile`:

```xml
<key>CFBundleIconName</key>
<string>AppIcon</string>
```

`Packaging/Info-dev.plist` is unchanged (dev stays `.icns`-only).

### `Makefile`

- **Toolchain guard**: before the `actool` step (e.g. in `bundle` or a small
  preflight), verify `xcrun --find actool` resolves under an Xcode toolchain and
  fail with a clear message pointing at
  `sudo xcode-select -s /Applications/Xcode.app` if it does not — mirroring the
  existing `test-toolchain` guidance.
- No new Makefile target for the layered icon: the committed `layers/*.svg`
  sources are imported directly into Icon Composer, and the committed
  `AppIcon.icon` is the source of truth thereafter.
- **`make icon`** (SVG→`.icns`) is unchanged.

## Manual authoring step (one-time, not automatable)

Documented procedure (README / CLAUDE.md icon section):

1. Open Icon Composer (Xcode 26 / standalone app). Create a new icon.
2. Set the **background** to the dark gradient (`#3C3C3C` top → `#1E1E1E`
   bottom).
3. Import `Packaging/AppIcon/layers/terminal.svg` and `sparkle.svg` directly as
   two **foreground layers**; tune material properties (specular / glass),
   applying glow to the sparkle layer.
4. Tune the **Dark** appearance (darker body, brighter sparkle) and verify the
   **Clear** appearance — confirm the sparkle silhouette reads as monochrome.
5. Export/save as `Packaging/AppIcon/AppIcon.icon` and commit it (the whole
   package directory: `icon.json` + `Assets/`).

## Verification

- **Structure**: after `make bundle`,
  `assetutil --info Casper.app/Contents/Resources/Assets.car` lists the
  `AppIcon` entry, and `plutil -p Casper.app/Contents/Info.plist` shows both
  `CFBundleIconName` and `CFBundleIconFile`.
- **Visual (macOS 26)**: install/run and inspect the Finder + Dock icon in
  Light, Dark, and Tinted system appearances (via the `debug-casper` screenshot
  skill).
- **Fallback (macOS 15–25)**: cannot be exercised without an older machine;
  verified structurally by the retained `AppIcon.icns` + `CFBundleIconFile`.

## Docs & memory

- Update `CLAUDE.md` Build & run (note the Xcode-26 `actool` prerequisite and
  the SVG-native manual authoring step) and any icon docs.
- Save a `skillbox:project-memory` note: the dual-key pipeline (both
  `CFBundleIconName` and `CFBundleIconFile`), keeping `.icns` for macOS 15–25,
  GUI-authored `.icon`, the `actool` bundling step, and the rationale for
  rejecting scripted `icon.json` and the split-icon workaround.

## Risks & notes

- The `icon.json` schema is undocumented and version-sensitive; because the
  `.icon` is committed and only re-authored in the GUI, build reproducibility is
  unaffected, but re-editing after an Xcode major upgrade should be re-verified.
- `actool`'s auto-generated `.icns` (when a low deployment target is set) is
  low-resolution and is **not** relied upon — the hand-crafted `AppIcon.icns`
  from `make icon` remains the fallback.
