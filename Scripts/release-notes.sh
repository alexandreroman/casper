#!/usr/bin/env bash
# Print the GitHub release description for a version: the body of its
# CHANGELOG.md section (the heading is dropped, since the release title already
# names the version), then the static install notes from
# Packaging/release-notes.md. Fails when the changelog has no entry for the
# version, so a release never ships without one.
#
# Both sources are hard-wrapped at 80 columns, but GitHub renders every newline
# in a release description as a line break, so the output is unwrapped: each
# paragraph and each list item comes out on a single line.
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

# Unwrap the whole description: a soft-wrapped line is joined onto the paragraph
# or list item above it with a single space. Only lines that start a new block
# are kept on their own: headings, list items (nested ones too), block quotes,
# thematic breaks, table rows and code fences, whatever their indentation.
# Headings, thematic breaks, block quotes and table rows are printed at once, so
# they never absorb the next line; a paragraph or list item is held in "pending"
# until a line shows it has ended. Lines inside a code fence pass through
# verbatim, and blank lines are kept as they are.
{
    printf '%s\n\n---\n\n' "$SECTION"
    cat "$INSTALL_NOTES"
} | awk '
    # The marker ("```" or "~~~") of a line that opens a code fence, or "" for
    # any other line.
    function fence_marker(line) {
        if (line ~ /^[ \t]*```/) {
            return "```"
        }
        if (line ~ /^[ \t]*~~~/) {
            return "~~~"
        }
        return ""
    }

    # A fence only closes on a line holding nothing but its own marker, so a
    # "```bash" line inside a "```" block stays part of the code.
    function closes_fence(line) {
        if (fence == "```") {
            return line ~ /^[ \t]*```+[ \t]*$/
        }
        return line ~ /^[ \t]*~~~+[ \t]*$/
    }

    function is_thematic_break(line,    compact) {
        compact = line
        gsub(/[ \t]/, "", compact)
        return compact ~ /^(---+|\*\*\*+|___+)$/
    }

    function is_standalone_block(line) {
        return line ~ /^[ \t]*#+([ \t]|$)/ || is_thematic_break(line) || line ~ /^[ \t]*[>|]/
    }

    function is_list_item(line) {
        return line ~ /^[ \t]*[-*+][ \t]/ || line ~ /^[ \t]*[0-9]+[.)][ \t]/
    }

    function flush_pending() {
        if (pending != "") {
            print pending
            pending = ""
        }
    }

    fence != "" {
        print
        if (closes_fence($0)) {
            fence = ""
        }
        next
    }
    fence_marker($0) != "" {
        flush_pending()
        print
        fence = fence_marker($0)
        next
    }
    /^[ \t]*$/ || is_standalone_block($0) {
        flush_pending()
        print
        next
    }
    is_list_item($0) || pending == "" {
        flush_pending()
        pending = $0
        next
    }
    {
        continuation = $0
        sub(/^[ \t]+/, "", continuation)
        sub(/[ \t]+$/, "", pending)
        pending = pending " " continuation
    }
    END {
        flush_pending()
    }
'
