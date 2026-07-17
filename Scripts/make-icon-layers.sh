#!/usr/bin/env bash
# Rasterize the Icon Composer foreground layer sources to 1024x1024 PNGs.
# These PNGs are import assets for the manual Icon Composer session that
# produces Packaging/AppIcon/AppIcon.icon; they are generated (gitignored),
# not committed. The committed AppIcon.icon is the source of truth.
#
# Usage: Scripts/make-icon-layers.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v resvg >/dev/null 2>&1; then
    echo "error: resvg not found — install with 'brew install resvg'" >&2
    exit 1
fi

LAYERS="$ROOT/Packaging/AppIcon/layers"
for name in terminal sparkle; do
    resvg --width 1024 --height 1024 "$LAYERS/$name.svg" "$LAYERS/$name.png"
    echo "Built $LAYERS/$name.png"
done
