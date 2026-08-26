#!/usr/bin/env bash
# Print the absolute path to one of Sparkle's command-line tools (sign_update,
# generate_keys, generate_appcast, BinaryDelta), downloading it on first use.
#
# The version is read from Package.resolved rather than hard-coded, so the tool
# that signs an update can never drift from the Sparkle framework the app is
# actually built against — a mismatch there produces signatures the shipped
# Sparkle rejects, which would only surface as a failed update in the field.
#
# Usage: "$(Scripts/sparkle-tool.sh sign_update)" --ed-key-file key.txt -p app.zip
set -euo pipefail

TOOL="${1:?usage: sparkle-tool.sh <sign_update|generate_keys|generate_appcast|BinaryDelta>}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

VERSION="$(python3 - "$ROOT/Package.resolved" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        resolved = json.load(f)
except OSError:
    sys.exit("error: Package.resolved not found — run 'swift build' first")
pins = resolved.get("pins", resolved.get("object", {}).get("pins", []))
for pin in pins:
    identity = pin.get("identity") or pin.get("package", "")
    if identity.lower() == "sparkle":
        state = pin.get("state", {})
        version = state.get("version")
        if not version:
            sys.exit("error: Sparkle is pinned to a revision, not a version")
        print(version)
        break
else:
    sys.exit("error: no Sparkle dependency found in Package.resolved")
PY
)"

# SwiftPM unpacks the whole Sparkle-for-Swift-Package-Manager.zip — which ships
# bin/ alongside the xcframework — so a completed build usually already has the
# tools on disk. Reuse them and skip the download, but only once the extracted
# artifact is confirmed to hold the pinned version: nothing in its path says
# which release it is, and a .build left behind by an older pin would otherwise
# sign with a tool the shipped Sparkle no longer matches.
CACHED="$(find "$ROOT/.build/artifacts" -type f -perm -100 -path "*/bin/$TOOL" -print -quit 2>/dev/null || true)"
if [ -n "$CACHED" ]; then
    ARTIFACT="${CACHED%/bin/$TOOL}"
    # The version is only recorded inside the framework the same zip ships.
    for plist in "$ARTIFACT"/Sparkle.xcframework/macos-*/Sparkle.framework/Resources/Info.plist; do
        [ -f "$plist" ] || continue
        if [ "$(plutil -extract CFBundleShortVersionString raw -o - "$plist" 2>/dev/null)" = "$VERSION" ]; then
            echo "$CACHED"
            exit 0
        fi
    done
fi

DEST="$ROOT/.build/sparkle-tools/$VERSION"
if [ ! -x "$DEST/bin/$TOOL" ]; then
    mkdir -p "$DEST"
    TARBALL="$DEST/Sparkle-$VERSION.tar.xz"
    # A failed curl or tar would otherwise leave a partial ~5 MB archive behind,
    # which the guard above never cleans up on the next run.
    trap 'rm -f "$TARBALL"' EXIT
    echo "==> downloading Sparkle $VERSION command-line tools" >&2
    curl -fsSL --retry 3 --retry-connrefused -o "$TARBALL" \
        "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz"
    tar -xJf "$TARBALL" -C "$DEST" ./bin
fi

if [ ! -x "$DEST/bin/$TOOL" ]; then
    echo "error: Sparkle $VERSION ships no '$TOOL' tool" >&2
    exit 1
fi

echo "$DEST/bin/$TOOL"
