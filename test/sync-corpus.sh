#!/usr/bin/env bash
# Refreshes the bundled fixture corpus from koreader-fixtures.
#
# The corpus sits in this repository so that the suite runs without a network
# and without a second checkout.  It is generated there by a pinned KOReader
# build in a clean environment; this script fetches the newest version and
# reports what changes.
#
#     test/sync-corpus.sh            # fetch and compare, change nothing
#     test/sync-corpus.sh --apply    # take the changes over as well
#
# Point at a checkout of your own with KOREADER_FIXTURES; otherwise a
# temporary clone is made.

set -uo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
here="$root/test/corpus"
upstream="https://github.com/jajpater/koreader-fixtures.git"
apply=""
[ "${1:-}" = "--apply" ] && apply=1

if [ -n "${KOREADER_FIXTURES:-}" ]; then
    source_dir="$KOREADER_FIXTURES"
    cleanup=""
else
    source_dir="$(mktemp -d)"
    cleanup="$source_dir"
    echo "cloning $upstream ..."
    if ! git clone --quiet --depth 1 "$upstream" "$source_dir"; then
        echo "clone failed" >&2
        rm -rf "$cleanup"
        exit 1
    fi
fi

corpus="$source_dir/corpus"
if [ ! -d "$corpus/generated" ]; then
    echo "no corpus found in $source_dir" >&2
    [ -n "$cleanup" ] && rm -rf "$cleanup"
    exit 1
fi

# The build hash is the proof of provenance: the same hash means the same
# KOReader, and therefore fixtures comparable with ours.
hash_of() {
    python3 - "$1" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as handle:
        print(json.load(handle)["koreader"]["build_sha256"][:12])
except Exception:
    print("unknown")
PY
}

echo "build here  : $(hash_of "$here/summary.json")"
echo "build there : $(hash_of "$corpus/reports/summary.json")"
echo

if diff -rq --exclude="summary*.json" "$here" "$corpus/generated" >/dev/null 2>&1; then
    echo "the corpus is up to date"
else
    echo "differences:"
    diff -rq --exclude="summary*.json" "$here" "$corpus/generated" 2>&1 | sed 's/^/  /' | head -30
fi

if [ -n "$apply" ]; then
    echo
    echo "taking over ..."
    rm -rf "$here"
    mkdir -p "$here"
    cp -r "$corpus"/generated/* "$here/"
    cp "$corpus"/reports/summary*.json "$here/" 2>/dev/null
    echo "done; check with test/run-tests.sh and commit what is right"
fi

[ -n "$cleanup" ] && rm -rf "$cleanup"
exit 0
