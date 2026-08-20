#!/usr/bin/env bash
# Assemble a self-contained Casper.app from the release binary: copy the binary,
# substitute the Info.plist version placeholders, bundle every non-system dylib
# (libgit2 + llhttp + libssh2 + transitive deps) into Contents/Frameworks and
# rewrite their load paths, then verify nothing non-relocatable remains.
#
# Usage: Scripts/bundle-app.sh <short-version> <bundle-version>
set -euo pipefail

SHORT_VERSION="${1:?usage: bundle-app.sh <short-version> <bundle-version>}"
BUNDLE_VERSION="${2:?usage: bundle-app.sh <short-version> <bundle-version>}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Same flags as the Makefile's `release` target, which exports them; the default
# keeps a standalone run of this script honest. Building the release with one set
# of flags and locating it with another risks resolving a different build
# directory (or planning a rebuild without them).
SWIFT_RELEASE_FLAGS="${SWIFT_RELEASE_FLAGS:--Xswiftc -Osize}"
# Word splitting is intended here: the variable holds several arguments.
# shellcheck disable=SC2086
BIN_DIR="$(swift build -c release $SWIFT_RELEASE_FLAGS --show-bin-path)"
BINARY="$BIN_DIR/casper"
if [ ! -x "$BINARY" ]; then
    echo "error: release binary not found at $BINARY (run 'make release' first)" >&2
    exit 1
fi

APP="$ROOT/Casper.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"

cp "$BINARY" "$APP/Contents/MacOS/casper"
chmod +x "$APP/Contents/MacOS/casper"

sed -e "s/__SHORT_VERSION__/${SHORT_VERSION}/g" \
    -e "s/__BUNDLE_VERSION__/${BUNDLE_VERSION}/g" \
    "$ROOT/Packaging/Info.plist" > "$APP/Contents/Info.plist"

# UNNotificationSound(named:) resolves the file from the bundle's Resources dir.
cp "$ROOT/Packaging/Sounds/NotificationAlert.aiff" "$APP/Contents/Resources/NotificationAlert.aiff"

# CFBundleIconFile (Info.plist) resolves AppIcon.icns from the bundle's Resources dir.
cp "$ROOT/Packaging/AppIcon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

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
    # that icns would clobber the hand-crafted high-res fallback copied above.
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

# HighlightSwift's generated Bundle.module ships as an ordinary sealed resource;
# DiffHighlighter mirrors it to the app root at runtime (where Bundle.module looks).
cp -R "$BIN_DIR/HighlightSwift_HighlightSwift.bundle" "$APP/Contents/Resources/HighlightSwift_HighlightSwift.bundle"

# Sparkle: embed the auto-update framework the release binary links against.
# The binary references it as @rpath/Sparkle.framework/Versions/B/Sparkle, and
# dylibbundler below points @rpath at Contents/Frameworks, so dropping the
# framework there is all the wiring needed.
#
# ditto, not cp: this is a versioned framework bundle whose Versions/Current
# symlinks and Apple code signature must survive the copy byte for byte. That
# signature seals Autoupdate, Updater.app and the XPC services nested inside —
# Sparkle launches those as separate processes during an install, and a broken
# seal there fails the update at the very last step.
SPARKLE_FRAMEWORK="$BIN_DIR/Sparkle.framework"
if [ ! -d "$SPARKLE_FRAMEWORK" ]; then
    echo "error: $SPARKLE_FRAMEWORK not found (run 'make release' first)" >&2
    exit 1
fi
ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
echo "Embedded Sparkle.framework -> Contents/Frameworks/"

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
RPATH="@executable_path/../Frameworks/"
while otool -l "$BUNDLED_BIN" | grep -qF "path $RPATH"; do
    install_name_tool -delete_rpath "$RPATH" "$BUNDLED_BIN" 2>/dev/null || break
done
install_name_tool -add_rpath "$RPATH" "$BUNDLED_BIN"
# Hard fail on anything but a single entry: duplicates make dyld warn on every
# launch, and none at all means the bundled dylibs are unreachable. Trailing
# slashes are normalized away first, since `--install-path` and the Makefile's
# dev bundle spell the same rpath without one.
rpath_count="$(otool -l "$BUNDLED_BIN" \
    | awk '/ cmd LC_RPATH$/ {in_rpath = 1; next} in_rpath && / path / {print $2; in_rpath = 0}' \
    | sed 's:/*$::' \
    | grep -cxF '@executable_path/../Frameworks' || true)"
if [ "$rpath_count" -ne 1 ]; then
    echo "error: $BUNDLED_BIN has $rpath_count @executable_path/../Frameworks LC_RPATH entries, expected 1" >&2
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
