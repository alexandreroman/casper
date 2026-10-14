#!/usr/bin/env bash
# Headless checks for Scripts/update-appcast.sh. A fake `curl` placed first on
# PATH stands in for GitHub, and the script runs from a scratch copy of the
# repository layout it reads, so the real appcast.xml at the repository root is
# never touched and nothing reaches the network.
#
# Usage: Scripts/test-update-appcast.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The fake curl writes $FAKE_CURL_FEED to the file named by `-o` and prints 200,
# or prints 404 when no feed is set, which is all update-appcast.sh reads back.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<'SH'
#!/usr/bin/env bash
out=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-o" ]; then
        out="$2"
        shift
    fi
    shift
done
if [ -n "${FAKE_CURL_FEED:-}" ]; then
    cp "$FAKE_CURL_FEED" "$out"
    printf '200'
else
    printf '404'
fi
SH
chmod +x "$WORK/bin/curl"

FAILURES=0

fail() {
    echo "FAIL: $1" >&2
    FAILURES=$((FAILURES + 1))
}

# A scratch repository holding only the files update-appcast.sh reads.
make_repo() {
    local repo="$1"
    mkdir -p "$repo/Scripts" "$repo/Packaging"
    cp "$ROOT/Scripts/update-appcast.sh" "$repo/Scripts/"
    cp "$ROOT/Packaging/appcast-template.xml" "$repo/Packaging/"
}

# Runs update-appcast.sh for build 42 (version 1.0.0) inside the given repo.
run_update() {
    local repo="$1"
    PATH="$WORK/bin:$PATH" "$repo/Scripts/update-appcast.sh" \
        1.0.0 42 https://h/o/r/releases/download/v1.0.0/a.zip 1 sig >/dev/null
}

count() {
    grep -c "$1" "$2" || true
}

# A feed already published by an earlier attempt of the same release: the item
# for build 42 sits on top of the one for build 41.
FEED="$WORK/published.xml"
sed -e 's|    <!-- ITEMS -->|&\
    <item>\
      <title>Casper 1.0.0</title>\
      <sparkle:version>42</sparkle:version>\
    </item>\
    <item>\
      <title>Casper 0.9.0</title>\
      <sparkle:version>41</sparkle:version>\
    </item>|' "$ROOT/Packaging/appcast-template.xml" > "$FEED"

echo "==> a re-run replaces the item of its own build"
REPO="$WORK/rerun"
make_repo "$REPO"
FAKE_CURL_FEED="$FEED" run_update "$REPO"
[ "$(count '<sparkle:version>42<' "$REPO/appcast.xml")" = 1 ] || fail "build 42 is listed more than once"
[ "$(count '<sparkle:version>41<' "$REPO/appcast.xml")" = 1 ] || fail "the item for build 41 was lost"
[ "$(count '<!-- ITEMS -->' "$REPO/appcast.xml")" = 1 ] || fail "the ITEMS marker is missing or doubled"
xmllint --noout "$REPO/appcast.xml" || fail "the re-run feed is not well-formed XML"

echo "==> the first release seeds the feed from the template"
REPO="$WORK/first"
make_repo "$REPO"
run_update "$REPO"
[ "$(count '<item>' "$REPO/appcast.xml")" = 1 ] || fail "the seeded feed does not hold exactly one item"
xmllint --noout "$REPO/appcast.xml" || fail "the seeded feed is not well-formed XML"

if [ "$FAILURES" -ne 0 ]; then
    echo "$FAILURES check(s) failed" >&2
    exit 1
fi
echo "All update-appcast.sh checks passed"
