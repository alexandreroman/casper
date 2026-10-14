#!/usr/bin/env bash
# Regenerate appcast.xml (the Sparkle feed): start from the previous feed
# published on the latest GitHub release, or the template on the very first
# release, then prepend a new <item> for this version (newest first), dropping
# any item the feed already holds for the same build number.
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
# The release bundle's own deployment target, so the feed never offers an update
# to a macOS the app would refuse to launch on.
MINIMUM_SYSTEM_VERSION="$(plutil -extract LSMinimumSystemVersion raw "$ROOT/Packaging/Info.plist")"
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
      <sparkle:minimumSystemVersion>${MINIMUM_SYSTEM_VERSION}</sparkle:minimumSystemVersion>
      <pubDate>${PUBDATE}</pubDate>
      <description><![CDATA[<h2>Casper ${SHORT_VERSION}</h2>
        <p><a href="${RELEASE_URL}">Read the full release notes on GitHub</a>.</p>]]></description>
      <enclosure url="${ZIP_URL}"
                 length="${ZIP_LEN}"
                 type="application/octet-stream"
                 sparkle:edSignature="${ED_SIGNATURE}" />
    </item>
EOF

# Replace the single marker with the new item (safe literal replace via python3).
# A re-run of a published release fetches a feed that already lists this build,
# so any item carrying the same sparkle:version goes first: the insert stays
# idempotent instead of doubling the item.
ITEM="$ITEM" BUNDLE_VERSION="$BUNDLE_VERSION" python3 - "$OUT" <<'PY'
import os, re, sys
path = sys.argv[1]
item = os.environ["ITEM"]
same_build = f"<sparkle:version>{os.environ['BUNDLE_VERSION']}</sparkle:version>"
with open(path, encoding="utf-8") as f:
    xml = f.read()


def drop_same_build(match):
    if same_build in match.group(0):
        return ""
    return match.group(0)


xml = re.sub(r"[ \t]*<item>.*?</item>\n?", drop_same_build, xml, flags=re.DOTALL)
marker = "    <!-- ITEMS -->"
found = xml.count(marker)
if found != 1:
    sys.exit(f"error: expected exactly 1 '{marker.strip()}' marker in {path}, found {found}")
xml = xml.replace(marker, item, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(xml)
PY

echo "Wrote $OUT (version $SHORT_VERSION, build $BUNDLE_VERSION)"
