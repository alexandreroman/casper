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

BIN_DIR="$(swift build -c release --show-bin-path)"
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

# HighlightSwift's generated Bundle.module ships as an ordinary sealed resource;
# DiffHighlighter mirrors it to the app root at runtime (where Bundle.module looks).
cp -R "$BIN_DIR/HighlightSwift_HighlightSwift.bundle" "$APP/Contents/Resources/HighlightSwift_HighlightSwift.bundle"

# Copy non-system dylibs into Contents/Frameworks and rewrite load commands to
# @executable_path/../Frameworks (recurses into transitive dependencies).
dylibbundler \
    --fix-file "$APP/Contents/MacOS/casper" \
    --dest-dir "$APP/Contents/Frameworks" \
    --install-path "@executable_path/../Frameworks" \
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
# Re-sign every bundled dylib ad-hoc as well: dylibbundler rewrote their install
# names, invalidating any prior signature, and an invalid signature is worse than
# an ad-hoc one on the target Mac. Sign nested code before the main executable.
find "$APP/Contents/Frameworks" -type f -name '*.dylib' -exec codesign --force --sign - {} +
codesign --force --sign - "$BUNDLED_BIN"

# Self-check (hard fail): every Mach-O in the bundle must reference only system
# libraries or relocatable (@rpath/@executable_path/@loader_path) paths. Any
# absolute Homebrew/local path means the app would not launch on a clean Mac.
non_relocatable() {
    local file="$1"
    otool -L "$file" | tail -n +2 | awk '{print $1}' | while read -r dep; do
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
done < <(printf '%s\n' "$APP/Contents/MacOS/casper"; find "$APP/Contents/Frameworks" -type f -name '*.dylib')

if [ "$status" -ne 0 ]; then
    echo "error: bundle contains non-relocatable dependencies — would not launch on a clean Mac" >&2
    exit 1
fi

echo "Built $APP (version $SHORT_VERSION, build $BUNDLE_VERSION)"
