#!/usr/bin/env bash
# Stage the parts of a Casper app bundle that the dev bundle (`make build`) and the
# release bundle (Scripts/bundle-app.sh) share: the Contents/ layout, the `casper`
# binary, the resources that resolve through Bundle.main, and the Sparkle
# framework the binary links against.
#
# Only that common core lives here. Everything the two flows do differently stays
# with the caller: the Info.plist (dev substitutes a bundle id, release a version),
# the rpath wiring, dylib bundling, the dSYM/strip pass and codesigning.
#
# The resolved SwiftPM bin directory goes to stdout so a caller can reuse it;
# every message goes to stderr.
#
# Usage: Scripts/assemble-bundle.sh <debug|release>
set -euo pipefail

CONFIGURATION="${1:?usage: assemble-bundle.sh <debug|release>}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

case "$CONFIGURATION" in
    debug)
        APP="$ROOT/Casper-dev.app"
        ICNS="AppIconDev.icns"
        BUILD_HINT="swift build"
        BIN_DIR="$(swift build --show-bin-path)"
        ;;
    release)
        APP="$ROOT/Casper.app"
        ICNS="AppIcon.icns"
        BUILD_HINT="make release"
        # Same flags as the Makefile's `release` target, which exports them; the
        # default keeps a standalone run of this script honest. Building the release
        # with one set of flags and locating it with another risks resolving a
        # different build directory (or planning a rebuild without them).
        SWIFT_RELEASE_FLAGS="${SWIFT_RELEASE_FLAGS:--Xswiftc -Osize}"
        # Word splitting is intended here: the variable holds several arguments.
        # shellcheck disable=SC2086
        BIN_DIR="$(swift build -c release $SWIFT_RELEASE_FLAGS --show-bin-path)"
        ;;
    *)
        echo "error: unknown configuration '$CONFIGURATION' (expected debug or release)" >&2
        exit 1
        ;;
esac

BINARY="$BIN_DIR/casper"
if [ ! -x "$BINARY" ]; then
    echo "error: $CONFIGURATION binary not found at $BINARY (run '$BUILD_HINT' first)" >&2
    exit 1
fi

SPARKLE_FRAMEWORK="$BIN_DIR/Sparkle.framework"
if [ ! -d "$SPARKLE_FRAMEWORK" ]; then
    echo "error: $SPARKLE_FRAMEWORK not found (run '$BUILD_HINT' first)" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"

cp "$BINARY" "$APP/Contents/MacOS/casper"
chmod +x "$APP/Contents/MacOS/casper"

# UNNotificationSound(named:) resolves the file from the bundle's Resources dir.
cp "$ROOT/Packaging/Sounds/NotificationAlert.aiff" "$APP/Contents/Resources/NotificationAlert.aiff"

# CFBundleIconFile (Info.plist) resolves the .icns from the bundle's Resources dir.
cp "$ROOT/Packaging/AppIcon/$ICNS" "$APP/Contents/Resources/$ICNS"

# HighlightSwift's generated Bundle.module ships as an ordinary sealed resource;
# DiffHighlighter mirrors it to the app root at runtime (where Bundle.module looks).
cp -R "$BIN_DIR/HighlightSwift_HighlightSwift.bundle" \
    "$APP/Contents/Resources/HighlightSwift_HighlightSwift.bundle"

# Sparkle: embed the auto-update framework the binary links against. It stays
# inert in dev builds (Info-dev.plist carries no SUFeedURL/SUPublicEDKey), but dyld
# must still find it: SwiftPM puts the framework next to the binary in the bin dir,
# where the binary finds it via @loader_path, and copying the binary out of there
# breaks that — hence this copy plus the caller's @executable_path rpath.
#
# ditto, not cp: this is a versioned framework bundle whose Versions/Current
# symlinks and Apple code signature must survive the copy byte for byte. That
# signature seals Autoupdate, Updater.app and the XPC services nested inside —
# Sparkle launches those as separate processes during an install, and a broken
# seal there fails the update at the very last step.
ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"

echo "Staged $APP from $BIN_DIR" >&2
printf '%s\n' "$BIN_DIR"
