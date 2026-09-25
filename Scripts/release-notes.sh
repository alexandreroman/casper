#!/usr/bin/env bash
# Print the GitHub release description for a version: the body of its
# CHANGELOG.md section (the heading is dropped, since the release title already
# names the version), then the static install notes from
# Packaging/release-notes.md. Fails when the changelog has no entry for the
# version, so a release never ships without one.
#
# Usage: Scripts/release-notes.sh <version>
set -euo pipefail

VERSION="${1:?usage: Scripts/release-notes.sh <version>}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHANGELOG="$ROOT/CHANGELOG.md"
INSTALL_NOTES="$ROOT/Packaging/release-notes.md"

# The section runs from its "## [<version>]" heading to the next "## " heading
# or the trailing link-reference block ("[label]: url"), whichever comes first.
# The heading is compared as a plain string prefix (index), never as a regex, so
# the dots in the version only match dots; it must be followed by the end of the
# line or a space. Blank lines are held back and only printed once more text
# follows, which trims them at both ends of the body. awk exits 1 when the
# heading is missing.
if ! SECTION="$(awk -v heading="## [$VERSION]" '
    found && (/^## / || /^\[[^]]+\]: /) { exit }
    found && /^[ \t]*$/ {
        if (printed) {
            pending_blank_lines++
        }
        next
    }
    found {
        for (; pending_blank_lines > 0; pending_blank_lines--) {
            print ""
        }
        print
        printed = 1
        next
    }
    index($0, heading) == 1 {
        after_heading = substr($0, length(heading) + 1, 1)
        if (after_heading == "" || after_heading == " ") {
            found = 1
        }
    }
    END {
        if (!found) {
            exit 1
        }
    }
' "$CHANGELOG")"; then
    echo "error: CHANGELOG.md has no '## [$VERSION]' section" >&2
    exit 1
fi

if [ -z "$SECTION" ]; then
    echo "error: the '## [$VERSION]' section of CHANGELOG.md is empty" >&2
    exit 1
fi

printf '%s\n\n---\n\n' "$SECTION"
cat "$INSTALL_NOTES"
