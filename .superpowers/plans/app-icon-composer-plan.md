# Icon Composer Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.
>
> **Project rule:** per `CLAUDE.md`, every change to a source file (SVG, shell
> script, Makefile, plist, Markdown docs) MUST be made by the **skillbox:code-writer**
> agent — never edit those files directly. This plan's code blocks are the
> instructions to hand that agent.

**Goal:** Ship a macOS 26 Liquid Glass app icon (Default / Dark / Clear
appearances) for the release build via a GUI-authored, committed `AppIcon.icon`
compiled by `actool`, while keeping the existing `AppIcon.icns` as the macOS
15–25 fallback.

**Architecture:** Purely additive. A new `actool` step in
`Scripts/bundle-app.sh` compiles `Packaging/AppIcon/AppIcon.icon` into
`Contents/Resources/Assets.car`; the release `Info.plist` gains
`CFBundleIconName` alongside the retained `CFBundleIconFile`. Layer art is
extracted from the existing `icon.svg` to seed a one-time manual Icon Composer
session that produces the committed `.icon`. The dev icon and the SVG→`.icns`
pipeline are untouched.

**Tech Stack:** Bash, Make, `resvg`, `xcrun actool` (Xcode 26), Icon
Composer.app, `iconutil`/`assetutil`/`plutil` (macOS), SwiftPM (unaffected).

## Global Constraints

- Platform: macOS 15+, arm64-only. `LSMinimumSystemVersion` = `15.0`.
- Toolchain for the icon build: **Xcode 26** selected via `xcode-select` (dev
  machine confirmed on macOS 26.5.2 / Xcode 26.6).
- The `.icon` bundle is named `AppIcon.icon`; `actool --app-icon AppIcon` ⇒
  `CFBundleIconName = AppIcon`, matching the existing `AppIcon.icns` /
  `CFBundleIconFile = AppIcon`.
- Do NOT remove `AppIcon.icns` or `CFBundleIconFile` — they are the pre-Tahoe
  fallback. Do NOT use the split-icon workaround
  (`--enable-icon-stack-fallback-generation`), unsupported as of Xcode 26.1.
- Dev build (`Casper-dev.app` / `Info-dev.plist`) stays `.icns`-only — do not touch it.
- Icon Composer max 4 foreground groups; this design uses 2.
- All source-file edits go through the `skillbox:code-writer` agent.

---

## Task ordering note

Tasks 1–3 and 6 are **agent-executable**. **Task 4 is a manual human step**
(the Icon Composer GUI session — no CLI can author the `.icon`). Task 5 (docs)
and Task 7 (final integration + memory) are agent-executable, but Task 7's full
`make bundle` verification only produces a layered icon *after* Task 4 has
committed `AppIcon.icon`. Until then, the `actool` step in Task 3 no-ops with a
warning so builds keep working.

---

### Task 1: Layer sources

Extract the two foreground layer groups from `icon.svg` as standalone
transparent SVGs, committed as the hand-editable source Icon Composer imports.

> **As built:** the planned `make icon-layers` target and
> `Scripts/make-icon-layers.sh` rasterizer were **not** built. Icon Composer
> imports the `layers/*.svg` sources directly, so there are no generated PNGs
> and nothing to gitignore.

**Files:**
- Create: `Packaging/AppIcon/layers/terminal.svg`
- Create: `Packaging/AppIcon/layers/sparkle.svg`

**Interfaces:**
- Produces: `Packaging/AppIcon/layers/{terminal,sparkle}.svg` at 1024×1024,
  transparent background. These are the manual-authoring inputs consumed by
  Task 4.


- [ ] **Step 1: Create `Packaging/AppIcon/layers/terminal.svg`**

Split line + cream caret only, transparent background, same coordinate
transforms as `icon.svg` so it aligns at 1024×1024:

```svg
<svg width="1024" height="1024" viewBox="0 0 1024 1024" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="Casper icon terminal layer">
  <!-- full-height split -->
  <line x1="512" y1="184" x2="512" y2="840" stroke="#8EF7DE" stroke-opacity="0.20" stroke-width="3.2"/>
  <!-- left pane: Ghostty prompt caret, cream -->
  <path transform="translate(100 100) scale(3.21875) translate(66 128) scale(15) translate(-7.83 -9.54)"
    d="M6.069 6.562a1 1 0 0 1 .46.131l3.578 2.065v.002a.974.974 0 0 1 0 1.687L6.53 12.512a.975.975 0 0 1-.976-1.687L7.67 9.602 5.553 8.38a.975.975 0 0 1 .515-1.818Z"
    fill="#F6F1E2"/>
</svg>
```

- [ ] **Step 2: Create `Packaging/AppIcon/layers/sparkle.svg`**

The sparkle only, keeping its gradient, WITHOUT the glow filter (glow becomes an
Icon Composer material effect), transparent background:

```svg
<svg width="1024" height="1024" viewBox="0 0 1024 1024" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="Casper icon sparkle layer">
  <defs>
    <linearGradient id="spark" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#FFDD86"/><stop offset="1" stop-color="#FF9E3D"/>
    </linearGradient>
  </defs>
  <!-- right pane: agent sparkle -->
  <path transform="translate(100 100) scale(3.21875)"
    d="M192 82 Q201.1 118.9 238 128 Q201.1 137.1 192 174 Q182.9 137.1 146 128 Q182.9 118.9 192 82 Z"
    fill="url(#spark)"/>
</svg>
```

- [x] **Step 3: Commit the layer sources**

The two SVGs are the committed, hand-editable source of truth; Icon Composer
imports them directly, so no rasterization step and no generated PNGs exist.

```bash
git add Packaging/AppIcon/layers/terminal.svg Packaging/AppIcon/layers/sparkle.svg
git commit -m "Add Icon Composer layer sources"
```

---

### Task 2: Add `CFBundleIconName` to the release Info.plist

**Files:**
- Modify: `Packaging/Info.plist` (add key after the existing `CFBundleIconFile`, lines 15–16)

**Interfaces:**
- Produces: release `Info.plist` carrying both `CFBundleIconName = AppIcon` and
  `CFBundleIconFile = AppIcon`. Consumed by macOS 26 (`CFBundleIconName` →
  `Assets.car` from Task 3) and macOS 15–25 (`CFBundleIconFile` →
  `AppIcon.icns`).

- [ ] **Step 1: Add the key**

In `Packaging/Info.plist`, immediately after:

```xml
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
```

insert:

```xml
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
```

- [ ] **Step 2: Verify the plist is still valid**

Run: `plutil -lint Packaging/Info.plist`
Expected: `Packaging/Info.plist: OK`

- [ ] **Step 3: Verify both keys are present**

Run: `plutil -extract CFBundleIconName raw Packaging/Info.plist && plutil -extract CFBundleIconFile raw Packaging/Info.plist`
Expected: prints `AppIcon` then `AppIcon`.

- [ ] **Step 4: Commit**

```bash
git add Packaging/Info.plist
git commit -m "Add CFBundleIconName to release Info.plist for Liquid Glass icon"
```

---

### Task 3: Compile `AppIcon.icon` into the bundle via `actool`

Add the `actool` step to the release bundler and a toolchain guard. The step is
conditional on `AppIcon.icon` existing so builds keep working until Task 4
authors it.

**Files:**
- Modify: `Scripts/bundle-app.sh` (add temp dir + trap near the top; add
  `actool` block right after the `AppIcon.icns` copy at line 38)

**Interfaces:**
- Consumes: `Packaging/AppIcon/AppIcon.icon` (produced by Task 4) if present;
  `CFBundleIconName` from Task 2.
- Produces: `Casper.app/Contents/Resources/Assets.car` (when the `.icon` exists).

- [ ] **Step 1: Add a temp dir with cleanup near the top of `bundle-app.sh`**

After the `cd "$ROOT"` line (line 14), add:

```bash
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
```

- [ ] **Step 2: Add the `actool` block after the `AppIcon.icns` copy (line 38)**

Directly after:

```bash
# CFBundleIconFile (Info.plist) resolves AppIcon.icns from the bundle's Resources dir.
cp "$ROOT/Packaging/AppIcon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
```

insert:

```bash
# macOS 26+ prefers the layered Liquid Glass icon: compile AppIcon.icon into
# Assets.car (resolved via CFBundleIconName). Requires Xcode 26's actool. The
# .icon is authored once in Icon Composer and committed; until it exists the
# build proceeds with the .icns fallback only.
ICON_SRC="$ROOT/Packaging/AppIcon/AppIcon.icon"
if [ -d "$ICON_SRC" ]; then
    if ! xcrun --find actool >/dev/null 2>&1; then
        echo "error: actool not found — select Xcode 26 with 'sudo xcode-select -s /Applications/Xcode.app'" >&2
        exit 1
    fi
    xcrun actool "$ICON_SRC" \
        --compile "$APP/Contents/Resources" \
        --app-icon AppIcon --include-all-app-icons \
        --output-partial-info-plist "$TMP/actool-partial.plist" \
        --platform macosx --target-device mac \
        --minimum-deployment-target 15.0 \
        --errors --warnings --notices --output-format human-readable-text
    if [ ! -f "$APP/Contents/Resources/Assets.car" ]; then
        echo "error: actool did not produce Assets.car" >&2
        exit 1
    fi
    echo "Compiled $ICON_SRC -> Contents/Resources/Assets.car"
else
    echo "note: $ICON_SRC not found — bundling .icns fallback only (no Liquid Glass icon)" >&2
fi
```

- [ ] **Step 3: Verify the script is syntactically valid**

Run: `bash -n Scripts/bundle-app.sh`
Expected: no output, exit code 0.

- [ ] **Step 4: Verify the no-`.icon` path (fallback still works)**

The `.icon` does not exist yet, so exercise the guard logic without a full release build. Run:

```bash
test -d Packaging/AppIcon/AppIcon.icon && echo "icon present" || echo "icon absent (expected pre-Task-4)"
```

Expected: `icon absent (expected pre-Task-4)` — confirming the `else` branch
(warn + continue) is the path a build would take now. (Full `make bundle`
verification is deferred to Task 7, after the `.icon` is committed, because it
is a slow release build.)

- [ ] **Step 5: Commit**

```bash
git add Scripts/bundle-app.sh
git commit -m "Compile AppIcon.icon into Assets.car during release bundling"
```

---

### Task 4: Author `AppIcon.icon` in Icon Composer (MANUAL — human step)

> This task cannot be executed by an agent: authoring the `.icon` is GUI-only.
> A human runs it once, then commits the result. The steps below are the
> procedure; the "verify" step is agent-checkable afterward.

**Files:**
- Create: `Packaging/AppIcon/AppIcon.icon/` (Icon Composer bundle: `icon.json` + `Assets/`)

**Interfaces:**
- Consumes: `Packaging/AppIcon/layers/{terminal,sparkle}.png` (Task 1).
- Produces: `Packaging/AppIcon/AppIcon.icon` consumed by Task 3's `actool` step.

- [ ] **Step 1: Locate the import sources**

The layer sources are `Packaging/AppIcon/layers/terminal.svg` and
`sparkle.svg`, committed by Task 1; Icon Composer imports them directly.

- [ ] **Step 2: Author the icon in Icon Composer**

Open Icon Composer (Xcode 26 ▸ Open Developer Tool ▸ Icon Composer, or the standalone app). Then:
1. New icon; set the canvas to macOS.
2. **Background**: a linear gradient, `#3C3C3C` (top) → `#1E1E1E` (bottom).
3. Add **`terminal.png`** as a foreground layer group (the split line + caret).
4. Add **`sparkle.png`** as a second foreground layer group; apply a
   glow/specular material so it reads as the glowing agent sparkle.
5. **Dark** appearance: darken the background gradient, brighten the sparkle.
6. **Clear** appearance: confirm the sparkle + caret silhouettes read as a clean
   monochrome; adjust layer opacity if muddy.

- [ ] **Step 3: Save into the repo**

Save/export as `Packaging/AppIcon/AppIcon.icon`.

- [ ] **Step 4: Verify it compiles (dry run)**

Run:

```bash
xcrun actool Packaging/AppIcon/AppIcon.icon --compile /tmp/casper-icon-check \
  --app-icon AppIcon --include-all-app-icons \
  --output-partial-info-plist /tmp/casper-icon-check-partial.plist \
  --platform macosx --target-device mac --minimum-deployment-target 15.0 \
  --errors --warnings --notices --output-format human-readable-text \
  && assetutil --info /tmp/casper-icon-check/Assets.car | grep -i AppIcon
```

Expected: `actool` exits 0 with no errors; `assetutil` lists an `AppIcon` entry.
(Warnings are acceptable.)

- [ ] **Step 5: Commit**

```bash
git add Packaging/AppIcon/AppIcon.icon
git commit -m "Add Icon Composer AppIcon.icon (Default/Dark/Clear appearances)"
```

---

### Task 5: Documentation

**Files:**
- Modify: `CLAUDE.md` (Build & run section — icon prerequisites + layer sources
  + manual authoring pointer)

**Interfaces:** none (docs only).

- [ ] **Step 1: Document the icon toolchain and workflow in `CLAUDE.md`**

In the "Build & run" section, near the existing `make vendor` / icon notes, add a paragraph:

```markdown
The app icon ships in two forms: the legacy `Packaging/AppIcon/AppIcon.icns`
(fallback for macOS 15–25, regenerated from `icon.svg` via `make icon`, needs
`brew install resvg`), and the macOS 26 Liquid Glass `Packaging/AppIcon/AppIcon.icon`
(Icon Composer bundle, compiled to `Assets.car` by `actool` during `make bundle`).
Both `CFBundleIconName` and `CFBundleIconFile` are set. Compiling the `.icon`
requires **Xcode 26** selected (`sudo xcode-select -s /Applications/Xcode.app`).
To re-author the layered icon: edit the layer sources
`Packaging/AppIcon/layers/*.svg`, re-import them into Icon Composer, and commit
the updated `AppIcon.icon`.
```

- [ ] **Step 2: Verify Markdown formatting**

Run: `grep -n "AppIcon.icon" CLAUDE.md`
Expected: at least one line matches; confirm lines stay within the project's
80-column Markdown limit.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "Document Icon Composer icon workflow in CLAUDE.md"
```

---

### Task 6: Integration verification + project memory

Runs after Task 4 has committed `AppIcon.icon`. Verifies the full bundle
produces a layered icon and records the decision.

**Files:**
- Create: a `skillbox:project-memory` note (via the skill; location per the skill).

**Interfaces:** none.

- [ ] **Step 1: Build the bundle**

Run: `make bundle`
Expected: ends with `Built …/Casper.app …`; includes the line
`Compiled …/AppIcon.icon -> Contents/Resources/Assets.car`.

- [ ] **Step 2: Verify both icon mechanisms are in the bundle**

Run:

```bash
plutil -extract CFBundleIconName raw Casper.app/Contents/Info.plist
plutil -extract CFBundleIconFile raw Casper.app/Contents/Info.plist
test -f Casper.app/Contents/Resources/Assets.car && echo "Assets.car present"
test -f Casper.app/Contents/Resources/AppIcon.icns && echo "AppIcon.icns present"
assetutil --info Casper.app/Contents/Resources/Assets.car | grep -i AppIcon
```

Expected: `AppIcon`, `AppIcon`, `Assets.car present`, `AppIcon.icns present`,
and an `AppIcon` entry from `assetutil`.

- [ ] **Step 3: Visual check on macOS 26 (Tahoe)**

Launch the bundled app (or reveal it in Finder) and inspect the Dock/Finder icon
under System Settings ▸ Appearance in **Light**, **Dark**, and a **Tinted**
highlight color. Optionally capture with the `debug-casper` screenshot skill.
Expected: distinct Default and Dark renderings; a clean monochrome Tinted
rendering.

- [ ] **Step 4: Record the decision in project memory**

Invoke the `skillbox:project-memory` skill to save a note capturing: the
dual-key pipeline (`CFBundleIconName` + `CFBundleIconFile`), keeping
`AppIcon.icns` for macOS 15–25, the GUI-authored committed `AppIcon.icon`, the
`actool` bundling step, and the rationale for rejecting scripted `icon.json` and
the split-icon workaround. Reference `.superpowers/plans/app-icon-composer.md`.

- [ ] **Step 5: Verify the memory note and index**

Run: `git status --porcelain .claude/project-memory/`
Expected: a new note file plus an updated `MEMORY.md` index entry.

- [ ] **Step 6: Commit**

```bash
git add .claude/project-memory/
git commit -m "Record Icon Composer icon-pipeline decision in project memory"
```

---

## Self-Review

**Spec coverage:**
- Committed `AppIcon.icon` with three appearances → Task 4. ✓
- Layer art extracted from `icon.svg` → Task 1. ✓
- `actool` step producing `Assets.car` → Task 3 (+ verified in Task 6). ✓
- `CFBundleIconName` added, `CFBundleIconFile` retained → Task 2. ✓
- Makefile toolchain guard → Task 3 (guard); committed layer sources → Task 1. ✓
- Manual authoring documented → Task 4 + Task 5. ✓
- Project-memory note → Task 6. ✓
- Dev build untouched → asserted in Global Constraints; no task modifies
  `Info-dev.plist`/dev icon. ✓
- Backward-compat (both files/keys, no split-icon workaround) → Tasks 2, 3, and
  Global Constraints. ✓
- Verification (`assetutil`, `plutil`, visual) → Task 6. ✓

**Placeholder scan:** No TBD/TODO; every code step contains complete file
content or exact commands. ✓

**Type/name consistency:** `AppIcon.icon`, `--app-icon AppIcon`,
`CFBundleIconName = AppIcon`, `Assets.car`, `terminal.svg`/`sparkle.svg` →
`terminal.png`/`sparkle.png` used consistently across Tasks 1–6. ✓
