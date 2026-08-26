#!/usr/bin/env bash
# Assemble a self-contained Casper.app from the release binary: stage the bundle
# via Scripts/assemble-bundle.sh, substitute the Info.plist version placeholders,
# compile the layered app icon, bundle every non-system dylib (libgit2 + llhttp +
# libssh2 + transitive deps) into Contents/Frameworks and rewrite their load paths,
# then strip, sign and verify nothing non-relocatable remains.
#
# Usage: Scripts/bundle-app.sh <short-version> <bundle-version>
set -euo pipefail

SHORT_VERSION="${1:?usage: bundle-app.sh <short-version> <bundle-version>}"
BUNDLE_VERSION="${2:?usage: bundle-app.sh <short-version> <bundle-version>}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Stage everything the dev bundle and the release bundle have in common (layout,
# binary, Resources, Sparkle.framework); the release-only steps follow below.
BIN_DIR="$("$ROOT/Scripts/assemble-bundle.sh" release)"
APP="$ROOT/Casper.app"

sed -e "s/__SHORT_VERSION__/${SHORT_VERSION}/g" \
    -e "s/__BUNDLE_VERSION__/${BUNDLE_VERSION}/g" \
    "$ROOT/Packaging/Info.plist" > "$APP/Contents/Info.plist"

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
    # Compile into a temp dir, not directly into Resources: actool also emits a
    # low-res AppIcon.icns (and a partial Info.plist) alongside Assets.car, and
    # that icns would clobber the hand-crafted high-res fallback already staged.
    # Take only Assets.car; the icns and partial plist are intentionally dropped.
    ICON_OUT="$TMP/iconout"
    mkdir -p "$ICON_OUT"
    xcrun actool "$ICON_SRC" \
        --compile "$ICON_OUT" \
        --app-icon AppIcon --include-all-app-icons \
        --output-partial-info-plist "$TMP/actool-partial.plist" \
        --platform macosx --target-device mac \
        --minimum-deployment-target 15.0 \
        --errors --warnings --notices --output-format human-readable-text
    if [ ! -f "$ICON_OUT/Assets.car" ]; then
        echo "error: actool did not produce Assets.car" >&2
        exit 1
    fi
    cp "$ICON_OUT/Assets.car" "$APP/Contents/Resources/Assets.car"
    echo "Compiled $ICON_SRC -> Contents/Resources/Assets.car"
else
    echo "note: $ICON_SRC not found — bundling .icns fallback only (no Liquid Glass icon)" >&2
fi

# The staged Sparkle.framework needs no further wiring: the binary references it
# as @rpath/Sparkle.framework/Versions/B/Sparkle, and dylibbundler below points
# @rpath at Contents/Frameworks.
#
# Copy non-system dylibs into Contents/Frameworks and rewrite load commands to
# @executable_path/../Frameworks (recurses into transitive dependencies).
#
# --ignore keeps dylibbundler away from Sparkle: left to itself it would resolve
# @rpath/Sparkle.framework/Versions/B/Sparkle, flatten that Mach-O into
# Frameworks/Sparkle and repoint the load command at it. The app would still
# launch, but Sparkle locates Autoupdate and its nibs through the bundle of its
# own class — which would then be Casper.app instead of the framework — and
# every update would fail. Copied whole above, the @rpath reference resolves to
# the framework as-is.
dylibbundler \
    --fix-file "$APP/Contents/MacOS/casper" \
    --dest-dir "$APP/Contents/Frameworks" \
    --install-path "@executable_path/../Frameworks" \
    --ignore "$BIN_DIR" \
    --ignore "$APP/Contents/Frameworks" \
    --bundle-deps --create-dir --overwrite-files

# dylibbundler rewrites each of the binary's pre-existing rpaths to the same
# @executable_path/../Frameworks value, leaving duplicate LC_RPATH entries that
# make dyld warn on every launch. Collapse them to a single entry, then re-sign
# ad-hoc (install_name_tool invalidates the signature dylibbundler applied).
BUNDLED_BIN="$APP/Contents/MacOS/casper"
RPATH="@executable_path/../Frameworks"

# The binary's LC_RPATH entries, one raw path per line.
rpath_entries() {
    otool -l "$BUNDLED_BIN" \
        | awk '/ cmd LC_RPATH$/ {in_rpath = 1; next} in_rpath && / path / {print $2; in_rpath = 0}'
}

# The first entry pointing at Contents/Frameworks, exactly as it is stored —
# dylibbundler writes a trailing slash and the Makefile's dev bundle does not,
# while `-delete_rpath` matches the stored string literally.
frameworks_rpath() {
    rpath_entries | awk -v want="$RPATH" '{
        normalized = $0
        sub(/\/+$/, "", normalized)
        if (normalized == want) { print; exit }
    }'
}

while true; do
    entry="$(frameworks_rpath)"
    [ -n "$entry" ] || break
    install_name_tool -delete_rpath "$entry" "$BUNDLED_BIN" 2>/dev/null || break
done
install_name_tool -add_rpath "$RPATH" "$BUNDLED_BIN"
# Hard fail on anything but a single entry: duplicates make dyld warn on every
# launch, and none at all means the bundled dylibs are unreachable. Trailing
# slashes are normalized away first, so an entry spelled with one still counts.
rpath_count="$(rpath_entries | sed 's:/*$::' | grep -cxF "$RPATH" || true)"
# `|| true` above absorbs grep's exit 1 on a zero count — and an otool failure
# with it, which leaves the count empty. An empty count would make the test
# below error out instead of failing, skipping the very branch that reports it.
rpath_count="${rpath_count:-0}"
if [ "$rpath_count" -ne 1 ]; then
    echo "error: $BUNDLED_BIN has $rpath_count $RPATH LC_RPATH entries, expected 1" >&2
    otool -l "$BUNDLED_BIN" | grep -A2 LC_RPATH >&2 || true
    exit 1
fi
# Re-sign every bundled dylib ad-hoc as well: dylibbundler rewrote their install
# names, invalidating any prior signature, and an invalid signature is worse than
# an ad-hoc one on the target Mac. Sign nested code before the main executable.
find "$APP/Contents/Frameworks" -type f -name '*.dylib' -exec codesign --force --sign - {} +

# Save the debug symbols outside Casper.app, then strip them from the shipped
# executable (~3.8 MB smaller). The dSYM stays out of the bundle because users
# have no use for it, while crash reports still symbolicate against the copy
# archived next to the release. Order is not negotiable: dsymutil needs the
# symbol table strip is about to remove, and strip rewrites the Mach-O, so it
# must run before the signature below rather than invalidate it afterwards.
DSYM="$ROOT/Casper.dSYM"
rm -rf "$DSYM"
dsymutil "$BUNDLED_BIN" --out "$DSYM"
strip -x "$BUNDLED_BIN"
echo "Saved debug symbols -> $DSYM"

codesign --force --sign - "$BUNDLED_BIN"

# Seal the bundle itself so Contents/Resources and Info.plist are covered too.
# Deliberately NOT --deep: that would re-sign the nested Sparkle.framework ad-hoc
# and destroy the Apple signature it must keep (verified below).
codesign --force --sign - "$APP"

# Sparkle is deliberately left out of the re-signing above: it keeps the Apple
# signature it shipped with. Assert the framework survived dylibbundler intact —
# a flattened Sparkle only shows up as a failed update months later.
if [ -e "$APP/Contents/Frameworks/Sparkle" ]; then
    echo "error: dylibbundler flattened Sparkle.framework into Contents/Frameworks/Sparkle" >&2
    exit 1
fi
if ! otool -L "$BUNDLED_BIN" | grep -q 'Sparkle\.framework/Versions/B/Sparkle'; then
    echo "error: the binary no longer loads Sparkle from its framework bundle" >&2
    otool -L "$BUNDLED_BIN" | grep -i sparkle >&2 || true
    exit 1
fi
codesign --verify "$APP/Contents/Frameworks/Sparkle.framework"
codesign --verify --strict "$APP"

# Self-check (hard fail): every Mach-O in the bundle must reference only system
# libraries or relocatable (@rpath/@executable_path/@loader_path) paths. Any
# absolute Homebrew/local path means the app would not launch on a clean Mac.
non_relocatable() {
    local file="$1"
    # Only tab-indented lines are load commands. Filtering on the tab (rather than
    # dropping the first line) is what keeps universal binaries honest: for a fat
    # Mach-O like Sparkle, otool repeats a "<path> (architecture arm64):" header
    # per slice, and those headers are absolute paths that read as violations.
    otool -L "$file" | awk '/^\t/ {print $1}' | while read -r dep; do
        case "$dep" in
            /usr/lib/*|/System/*|@rpath/*|@executable_path/*|@loader_path/*) ;;
            *) echo "$dep" ;;
        esac
    done
}

status=0
while IFS= read -r macho; do
    bad="$(non_relocatable "$macho")"
    if [ -n "$bad" ]; then
        echo "error: $macho still links non-relocatable dependencies:" >&2
        echo "$bad" | sed 's/^/  /' >&2
        status=1
    fi
done < <(printf '%s\n' "$APP/Contents/MacOS/casper" \
    "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"; \
    find "$APP/Contents/Frameworks" -type f -name '*.dylib')

if [ "$status" -ne 0 ]; then
    echo "error: bundle contains non-relocatable dependencies — would not launch on a clean Mac" >&2
    exit 1
fi

echo "Built $APP (version $SHORT_VERSION, build $BUNDLE_VERSION)"
