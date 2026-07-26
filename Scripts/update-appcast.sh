#!/usr/bin/env bash
# Regenerate appcast.xml (the Sparkle feed): start from the previous feed
# published on the latest GitHub release, or the template on the very first
# release, then prepend a new <item> for this version (newest first).
#
# Usage: Scripts/update-appcast.sh <short-version> <bundle-version> <zip-url> <zip-length> <ed-signature>
set -euo pipefail

SHORT_VERSION="${1:?}"
BUNDLE_VERSION="${2:?}"
ZIP_URL="${3:?}"
ZIP_LEN="${4:?}"
# No apostrophe in this message: bash parses quotes inside ${var:?word}, and a
# stray one silently swallows the rest of the script.
ED_SIGNATURE="${5:?missing EdDSA signature — sign the zip with sign_update first}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${GITHUB_REPOSITORY:-alexandreroman/casper}"
OUT="$ROOT/appcast.xml"
PUBDATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
# The human-readable release page for this version, derived from the enclosure
# URL: .../releases/download/<tag>/<file> -> .../releases/tag/<tag>.
ASSET_DIR="${ZIP_URL%/*}"
RELEASE_TAG="${ASSET_DIR##*/}"
RELEASE_URL="${ASSET_DIR%/releases/download/*}/releases/tag/${RELEASE_TAG}"

# Seed from the previously published feed. Only a genuine 404 (no prior feed)
# falls back to the empty template; any other outcome is fatal so a transient
# network blip cannot silently truncate the release history. Retries cover
# flaky connectivity. Note: no -f, so curl still returns 0 on 404 and we read
# the real HTTP status from -w.
HTTP="$(curl -sL --retry 3 --retry-connrefused -w '%{http_code}' -o "$OUT" \
    "https://github.com/$REPO/releases/latest/download/appcast.xml" || echo 000)"
case "$HTTP" in
    200) ;;
    404) cp "$ROOT/Packaging/appcast-template.xml" "$OUT" ;;
    *)   echo "error: could not fetch existing appcast (HTTP $HTTP)" >&2; exit 1 ;;
esac

# Re-emit the marker BEFORE the new item so each release prepends (newest first).
IFS= read -r -d '' ITEM <<EOF || true
    <!-- ITEMS -->
    <item>
      <title>Casper ${SHORT_VERSION}</title>
      <link>${RELEASE_URL}</link>
      <sparkle:version>${BUNDLE_VERSION}</sparkle:version>
      <sparkle:shortVersionString>${SHORT_VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <pubDate>${PUBDATE}</pubDate>
      <description><![CDATA[<h2>Casper ${SHORT_VERSION}</h2><p><a href="${RELEASE_URL}">Read the full release notes on GitHub</a>.</p>]]></description>
      <enclosure url="${ZIP_URL}" length="${ZIP_LEN}" type="application/octet-stream" sparkle:edSignature="${ED_SIGNATURE}" />
    </item>
EOF

# Replace the single marker with the new item (safe literal replace via python3).
ITEM="$ITEM" python3 - "$OUT" <<'PY'
import os, sys
path = sys.argv[1]
item = os.environ["ITEM"]
with open(path, encoding="utf-8") as f:
    xml = f.read()
xml = xml.replace("    <!-- ITEMS -->", item, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(xml)
PY

echo "Wrote $OUT (version $SHORT_VERSION, build $BUNDLE_VERSION)"
