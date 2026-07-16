#!/usr/bin/env bash
# Regenerate both committed .icns files from their SVG masters: rasterize the 10
# standard iconset sizes with resvg, then pack them into an .icns via iconutil.
#   Packaging/AppIcon/icon.svg     -> Packaging/AppIcon/AppIcon.icns    (release)
#   Packaging/AppIcon/icon-dev.svg -> Packaging/AppIcon/AppIconDev.icns (dev)
# The .icns files are committed so ordinary builds need no rasterizer; run this
# only when an SVG master changes.
#
# Usage: Scripts/make-icon.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v resvg >/dev/null 2>&1; then
    echo "error: resvg not found — install with 'brew install resvg'" >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Rasterize one SVG master into its .icns. iconutil requires the iconset
# directory name to end in .iconset, so render into a subdirectory named after
# the destination (keeping multiple runs separate). The @2x variants share a
# pixel size with the next tier up, but iconutil needs both filenames present.
build_icns() {
    local svg="$1" icns="$2"
    local iconset="$TMP/$(basename "$icns" .icns).iconset"
    mkdir -p "$iconset"

    render() { resvg --width "$2" --height "$2" "$svg" "$iconset/$1.png"; }
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

    iconutil -c icns "$iconset" -o "$icns"
    echo "Built $icns from $svg"
}

build_icns "$ROOT/Packaging/AppIcon/icon.svg" "$ROOT/Packaging/AppIcon/AppIcon.icns"
build_icns "$ROOT/Packaging/AppIcon/icon-dev.svg" "$ROOT/Packaging/AppIcon/AppIconDev.icns"
