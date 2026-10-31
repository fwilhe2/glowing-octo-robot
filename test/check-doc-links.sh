#!/usr/bin/env bash
# Every relative link in the documentation names a file or directory that exists:
#
#     ./test/check-doc-links.sh          # the markdown git tracks
#     ./test/check-doc-links.sh <dir>    # every *.md under a directory (test/selftest.sh)
#
# The check a documentation-only change gets in CI (the `docs` job in ci.yml), where the
# image build is skipped: a moved guide or a renamed script is what such a change breaks.
# Links with a scheme (https:, mailto:) and bare #anchors are not followed, and a
# fragment is dropped before the path is checked; fenced code blocks are skipped.
set -euo pipefail

cd "$(dirname "$0")/.."

if [ $# -gt 0 ]; then
    root=$1
    files=$(cd "$root" && find . -name '*.md' -type f | sed 's|^\./||' | LC_ALL=C sort)
else
    root=.
    files=$(git ls-files '*.md')
fi
[ -n "$files" ] || { echo "error: no markdown files under $root" >&2; exit 1; }

broken=0 checked=0
while IFS= read -r f; do
    dir=$(dirname "$f")
    # Inline links' targets, outside fenced code blocks: the text between `](` and the
    # first space or `)`, so a title in quotes after the target is left out.
    targets=$(awk '/^[[:space:]]*(```|~~~)/ { fence = !fence; next } !fence' "$root/$f" |
        grep -o '\]([^)[:space:]]*' | sed 's/^](//' || true)
    for t in $targets; do
        case "$t" in
            ''|'#'*) continue ;;
            [a-zA-Z]*:*) case "${t%%:*}" in *[!a-zA-Z0-9+.-]*) ;; *) continue ;; esac ;;
        esac
        path=${t%%#*}
        path=${path%%\?*}
        [ -n "$path" ] || continue
        case "$path" in
            /*) resolved="$root$path" ;;
            *)  resolved="$root/$dir/$path" ;;
        esac
        checked=$((checked + 1))
        if [ ! -e "$resolved" ]; then
            echo "BROKEN  $f: ($t)"
            broken=$((broken + 1))
        fi
    done
done <<< "$files"

if [ "$broken" -gt 0 ]; then
    echo "$broken broken link(s) in $(wc -l <<< "$files" | tr -d ' ') markdown file(s)" >&2
    exit 1
fi
echo "All $checked relative links in $(wc -l <<< "$files" | tr -d ' ') markdown file(s) resolve."
