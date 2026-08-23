#!/usr/bin/env bash
#
# memory-watch.sh — watch a running Casper dev instance for memory growth.
#
# Debug builds only: it drives `casper debug memory`, which exists only under
# `#if DEBUG`. Start the app first (`make dev`), then run this from a shell that
# can reach it.
#
# Subcommands
#   sample [--count N] [--interval SECONDS]
#       Take N memory samples and report how the process grew between them.
#       Defaults: --count 5, --interval 2.
#
#   churn [--cycles N] [--settle SECONDS]
#       Stress the terminal lifecycle: open a terminal, let it settle, close it,
#       let it settle, N times over. Samples memory before the first cycle and
#       after the last one. Defaults: --cycles 10, --settle 1.
#
# Output — two tables, because a single row per sample would be far too wide once
# every object label and counter is a column of its own:
#   1. one row per sample: footprint, resident and peak MB, plus the footprint
#      delta against the first sample;
#   2. one row per tracked object label / named counter, one column per sample,
#      plus its first-to-last delta. Labels with a zero live *and* zero created
#      count are omitted.
# A final line reports the total footprint growth.
#
# Environment
#   CASPER_BIN              casper binary to drive (default: .build/debug/casper)
#   CASPER_SESSION          picks the app's debug socket, for `casper debug`
#   CASPER_CONTROL_SOCKET   picks the app's control socket, for `casper terminal`
#   CASPER_WORKSPACE_ID     workspace `casper terminal` acts on
# All four are read from the ambient environment — nothing here is hardcoded, so
# run this the same way you would run `casper` by hand.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASPER_BIN="${CASPER_BIN:-$REPO_ROOT/.build/debug/casper}"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

die() {
    printf 'memory-watch: %s\n' "$*" >&2
    exit 1
}

# Reject an option value that is not a plain whole number. `count` and `cycles`
# end up as `for ((...))` operands, and bash evaluates an arithmetic operand's
# *value* recursively as an expression — an array subscript inside it is command
# substituted — so an unvalidated value is a command-injection vector, not merely
# a bad number.
require_whole_number() {
    [[ $2 =~ ^[0-9]+$ ]] || die "$1 needs a whole number, got: $2"
}

# Same, for the values that reach `sleep`, which accepts a fractional interval.
require_seconds() {
    [[ $2 =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "$1 needs a number of seconds, got: $2"
}

usage() {
    cat <<'USAGE'
usage: memory-watch.sh sample [--count N] [--interval SECONDS]
       memory-watch.sh churn  [--cycles N] [--settle SECONDS]

sample  take N memory samples (default 5) SECONDS apart (default 2)
churn   open and close a terminal N times (default 10), settling SECONDS
        (default 1) after each step, sampling memory before and after

Needs a running debug build (make dev). See the comments at the top of this
script for the environment variables it honors.
USAGE
    exit "${1:-0}"
}

# Write one `casper debug memory` snapshot to $1. A failure here almost always
# means the app is not running, or is running under a different session.
take_sample() {
    local out_file="$1" stderr_file="$WORK_DIR/stderr"
    if ! "$CASPER_BIN" debug memory >"$out_file" 2>"$stderr_file"; then
        printf 'memory-watch: cannot reach the running app.\n' >&2
        printf '  %s debug memory said: %s\n' "$CASPER_BIN" "$(cat "$stderr_file")" >&2
        printf '  CASPER_SESSION=%s CASPER_DEBUG_SOCKET=%s\n' \
            "${CASPER_SESSION:-<unset>}" "${CASPER_DEBUG_SOCKET:-<unset>}" >&2
        printf '  Start a debug build first (make dev), and export the same CASPER_SESSION.\n' >&2
        exit 1
    fi
}

# Render every sample file passed as an argument.
report() {
    python3 "$WORK_DIR/render.py" "$@"
}

open_terminal() {
    local out
    out="$("$CASPER_BIN" terminal new)" \
        || die "'casper terminal new' failed — is CASPER_WORKSPACE_ID set?"
    # `terminal new` keys the new terminal's id by its type name (see the
    # domain-cli-control-channel note), so read "terminal", never a bare "id".
    printf '%s' "$out" | python3 -c 'import json, sys; print(json.load(sys.stdin)["terminal"])'
}

close_terminal() {
    "$CASPER_BIN" terminal close "$1" >/dev/null \
        || die "'casper terminal close $1' failed"
}

cmd_sample() {
    local count=5 interval=2
    while [ $# -gt 0 ]; do
        case "$1" in
            --count)
                count="${2:?--count needs a value}"
                require_whole_number --count "$count"
                # At least one: a zero count leaves `files` empty, and expanding an
                # empty array trips `set -u` under the bash 3.2 macOS still ships.
                [ "$count" -ge 1 ] || die "--count needs at least 1 sample, got: $count"
                shift 2
                ;;
            --interval)
                interval="${2:?--interval needs a value}"
                require_seconds --interval "$interval"
                shift 2
                ;;
            -h|--help) usage ;;
            *) die "unknown option for 'sample': $1" ;;
        esac
    done

    local files=() i
    for ((i = 0; i < count; i++)); do
        [ "$i" -eq 0 ] || sleep "$interval"
        take_sample "$WORK_DIR/sample-$i.json"
        files+=("$WORK_DIR/sample-$i.json")
    done
    report "${files[@]}"
}

cmd_churn() {
    local cycles=10 settle=1
    while [ $# -gt 0 ]; do
        case "$1" in
            --cycles)
                # Zero is allowed here: it samples before and after doing nothing,
                # which is a useful idle baseline.
                cycles="${2:?--cycles needs a value}"
                require_whole_number --cycles "$cycles"
                shift 2
                ;;
            --settle)
                settle="${2:?--settle needs a value}"
                require_seconds --settle "$settle"
                shift 2
                ;;
            -h|--help) usage ;;
            *) die "unknown option for 'churn': $1" ;;
        esac
    done

    take_sample "$WORK_DIR/sample-0.json"
    local i terminal
    for ((i = 1; i <= cycles; i++)); do
        printf 'cycle %d/%d\n' "$i" "$cycles" >&2
        terminal="$(open_terminal)"
        sleep "$settle"
        close_terminal "$terminal"
        sleep "$settle"
    done
    take_sample "$WORK_DIR/sample-1.json"
    report "$WORK_DIR/sample-0.json" "$WORK_DIR/sample-1.json"
}

cat >"$WORK_DIR/render.py" <<'PYTHON'
"""Render the sampled `casper debug memory` payloads as two aligned tables."""
import json
import sys

MB = 1024 * 1024


def load(paths):
    samples = []
    for path in paths:
        with open(path, encoding="utf-8") as handle:
            samples.append(json.load(handle))
    return samples


def table(rows):
    """Print rows of equal length, every column padded to its widest cell."""
    widths = [max(len(row[i]) for row in rows) for i in range(len(rows[0]))]
    for row in rows:
        cells = [cell.ljust(widths[i]) for i, cell in enumerate(row)]
        print("  ".join(cells).rstrip())


def process_table(samples):
    base = samples[0]["footprintBytes"]
    rows = [["#", "footprint MB", "resident MB", "peak MB", "delta MB"]]
    for index, sample in enumerate(samples):
        rows.append([
            str(index),
            "%.1f" % (sample["footprintBytes"] / MB),
            "%.1f" % (sample["residentBytes"] / MB),
            "%.1f" % (sample["peakFootprintBytes"] / MB),
            "%+.1f" % ((sample["footprintBytes"] - base) / MB),
        ])
    table(rows)


def live_counts(sample):
    """Live count per label, skipping labels nothing was ever tracked under."""
    return {
        entry["label"]: entry["live"]
        for entry in sample.get("liveObjects", [])
        if entry["live"] or entry["created"]
    }


def metric_table(samples, extract, heading):
    """One row per metric, one column per sample — a row per sample would put
    every object label and counter on its own column and blow the width."""
    series = [extract(sample) for sample in samples]
    names = sorted({name for metrics in series for name in metrics})
    if not names:
        return
    print()
    print(heading)
    rows = [[""] + ["s%d" % i for i in range(len(samples))] + ["delta"]]
    for name in names:
        values = [metrics.get(name, 0) for metrics in series]
        rows.append([name] + [str(value) for value in values]
                    + ["%+d" % (values[-1] - values[0])])
    table(rows)


def main():
    if len(sys.argv) < 2:
        sys.exit("render.py: no samples")
    samples = load(sys.argv[1:])
    process_table(samples)
    metric_table(samples, live_counts, "live objects")
    metric_table(samples, lambda sample: sample.get("counters", {}), "counters")
    growth = (samples[-1]["footprintBytes"] - samples[0]["footprintBytes"]) / MB
    print()
    print("total footprint growth: %+.1f MB over %d samples" % (growth, len(samples)))


main()
PYTHON

[ -x "$CASPER_BIN" ] \
    || die "no casper binary at $CASPER_BIN — run 'make build', or set CASPER_BIN"

case "${1:-}" in
    sample) shift; cmd_sample "$@" ;;
    churn) shift; cmd_churn "$@" ;;
    -h|--help|"") usage ;;
    *) printf 'memory-watch: unknown subcommand: %s\n\n' "$1" >&2; usage 1 ;;
esac
