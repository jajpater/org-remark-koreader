#!/usr/bin/env bash
# Runs the full org-remark-koreader suite.
#
# org-remark is looked for in the elpa directory of the development Emacs.
# Point at it yourself when needed:
#
#     ORG_REMARK_DIR=/pad/naar/org-remark test/run-tests.sh
#
# Without org-remark the reader, model and match tests run as usual; the
# integration tests and the two contract tests then report as `skipped'.

set -uo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

if [ -z "${ORG_REMARK_DIR:-}" ]; then
    ORG_REMARK_DIR="$(ls -d "$HOME"/.local/share/emacs-dev/.emacs.d/elpa/*/*/org-remark-* 2>/dev/null | head -1)"
fi

load_path=(-L .)
if [ -n "${ORG_REMARK_DIR:-}" ] && [ -d "$ORG_REMARK_DIR" ]; then
    load_path+=(-L "$ORG_REMARK_DIR")
    echo "org-remark: $ORG_REMARK_DIR"
else
    echo "org-remark: not found — integration tests will be skipped"
fi

# nov.el and its dependencies.  Without them the EPUB integration tests skip
# themselves; the rest of the suite runs as usual.
nov_found=""
for package in nov esxml dash; do
    dir="$(ls -d "$HOME"/.local/share/emacs-dev/.emacs.d/elpa/*/*/"$package"-* 2>/dev/null | head -1)"
    if [ -n "$dir" ] && [ -d "$dir" ]; then
        load_path+=(-L "$dir")
        [ "$package" = nov ] && nov_found=1
    else
        echo "$package: not found — EPUB integration tests will be skipped"
    fi
done

# A stale .elc shadows the .el; Emacs prefers the compiled version.
rm -f ./*.elc test/*.elc

status=0
for file in test/*-tests.el; do
    name="$(basename "$file" .el)"
    printf '%-42s ' "$name"
    output="$(emacs --batch -Q "${load_path[@]}" -l ert -l "$file" \
                    -f ert-run-tests-batch-and-exit 2>&1)"
    line="$(printf '%s\n' "$output" | grep -E '^Ran ')"
    if printf '%s\n' "$output" | grep -qE 'FAILED|unexpected results'; then
        status=1
        printf '%s\n' "$line"
        printf '%s\n' "$output" | grep -E 'FAILED' | sed 's/^/    /'
    else
        printf '%s\n' "$line"
    fi
done

printf '%-42s ' "analyse-fixtures.el (md-txt)"
if [ -d test/corpus/md-txt ]; then
    emacs --batch -Q -L . -l test/analyse-fixtures.el \
          -f org-remark-koreader-fixtures-main test/corpus/md-txt 2>&1 |
        grep -E '^total:'
else
    echo "corpus not found — skipped"
fi

printf '%-42s ' "analyse-epub.el"
if [ -d test/corpus/epub ] && [ -n "$nov_found" ]; then
    emacs --batch -Q "${load_path[@]}" \
          --eval '(setq nov-text-width t nov-variable-pitch nil)' \
          -l test/analyse-epub.el -f org-remark-koreader-epub-report 2>&1 |
        grep -E '^total:'
else
    echo "corpus or nov.el not found — skipped"
fi

exit $status
