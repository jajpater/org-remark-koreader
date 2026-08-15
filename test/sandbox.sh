#!/usr/bin/env bash
# Puts a document with its KOReader sidecar ready in a throwaway directory.
#
# Importing writes a marginalia.org beside the source file.  In the repository
# that is pollution — certainly in the fixture directories, which are meant to
# have controlled contents.  This copy lives outside the repository, so there
# anything goes.
#
# Usage:
#
#     test/sandbox.sh                  # show which documents there are
#     test/sandbox.sh fixture          # the controlled v2026.07 fixture
#     test/sandbox.sh 005-duplicates   # a fixture from the corpus
#     test/sandbox.sh epub/001-basic   # the same, but an EPUB
#
# Open the path that comes out in Emacs; there you call
# `org-remark-koreader-import'.

set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$root/test/fixtures/koreader-v2026.07-basic"
corpus="$root/test/corpus"

available() {
    printf '  fixture   (the controlled v2026.07 fixture)\n'
    for dir in "$corpus"/md-txt/*/; do
        [ -d "$dir" ] && printf '  %s\n' "$(basename "$dir")"
    done
    for dir in "$corpus"/epub/*/; do
        [ -d "$dir" ] && printf '  epub/%s\n' "$(basename "$dir")"
    done
}

if [ $# -eq 0 ]; then
    printf 'Name a document:\n'
    available
    exit 1
fi

case "$1" in
    fixture)      source_dir="$fixture" ;;
    epub/*)       source_dir="$corpus/epub/${1#epub/}" ;;
    *)            source_dir="$corpus/md-txt/$1" ;;
esac

if [ ! -d "$source_dir" ]; then
    printf 'Unknown: %s. Available:\n' "$1"
    available
    exit 1
fi

# The source file is called `source' with a varying extension: .md, .txt or
# .epub.
source_file="$(find "$source_dir" -maxdepth 1 -type f -name 'source.*' | head -1)"
sidecar_dir="$(find "$source_dir" -maxdepth 1 -type d -name '*.sdr' | head -1)"

if [ -z "$source_file" ] || [ -z "$sidecar_dir" ]; then
    printf 'Source or sidecar missing in %s\n' "$source_dir" >&2
    exit 1
fi

work="$(mktemp -d -t org-remark-koreader-XXXXXX)"
cp "$source_file" "$work/"
cp -r "$sidecar_dir" "$work/"

printf 'Put ready in a throwaway directory:\n\n'
printf '  %s\n\n' "$work/$(basename "$source_file")"
printf 'Open that file in Emacs and call org-remark-koreader-import.\n'
printf 'The marginalia will sit beside it, outside the repository.\n\n'
printf 'Clean up when you are done:\n\n'
printf '  rm -rf %s\n' "$work"
