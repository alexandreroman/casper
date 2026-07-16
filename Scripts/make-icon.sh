#!/usr/bin/env bash
# Regenerate Packaging/AppIcon/AppIcon.icns from the icon.svg master: rasterize the
# 10 standard iconset sizes with resvg, then pack them into an .icns via iconutil.
# The .icns is committed so ordinary builds need no rasterizer; run this only when
# icon.svg changes.
#
# Usage: Scripts/make-icon.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v resvg >/dev/null 2>&1; then
    echo "error: resvg not found — install with 'brew install resvg'" >&2
    exit 1
fi

SVG="$ROOT/Packaging/AppIcon/icon.svg"
ICNS="$ROOT/Packaging/AppIcon/AppIcon.icns"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# iconutil requires the iconset directory name to end in .iconset, so render into
# a suitably named subdirectory of the temp parent.
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"

# name:size pairs for the standard macOS iconset (@2x variants share a pixel size
# with the next tier up, but iconutil needs both filenames present).
render() {
    local name="$1" size="$2"
    resvg --width "$size" --height "$size" "$SVG" "$ICONSET/$name.png"
}

render icon_16x16 16
render icon_16x16@2x 32
render icon_32x32 32
render icon_32x32@2x 64
render icon_128x128 128
render icon_128x128@2x 256
render icon_256x256 256
render icon_256x256@2x 512
render icon_512x512 512
render icon_512x512@2x 1024

iconutil -c icns "$ICONSET" -o "$ICNS"

echo "Built $ICNS from $SVG"
