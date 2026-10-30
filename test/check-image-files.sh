#!/usr/bin/env bash
# Hold the assembled images to what must, and must not, be in them:
#
#     ./test/check-image-files.sh                                  # both flavours from output/
#     ./test/check-image-files.sh output/rootfs-files-erofs.txt    # one manifest
#     RULES=some/dir ./test/check-image-files.sh manifest.txt      # other rules (selftest)
#
# image/build-rootfs.sh writes a manifest of every path in each assembled tree, because
# that is the only place the tree exists: rootfs/ is the input and still carries
# everything the trim and the subtractions remove. This reads it back against the rule
# files in test/image-files/, one per topic, each line one of
#
#     absent  <glob>    no path in the image may match
#     present <glob>    at least one path must match
#
# with the reason in a comment above it. A glob is bash's [[ == ]] pattern, matched
# against the whole path without the leading slash, so `*` crosses directories. A rule
# for one flavour only says so, `absent:erofs` or `present:oci`; the manifest's first
# line, `# flavour: <name>`, is what it is matched against.
#
# Why this exists: a removal — a meson option off, a configure flag, a trim line — is
# undone silently. A version bump renames a file and the trim's `rm -f` matches nothing,
# or a new release turns a component back on by default, and every check that asks
# whether the image *works* still passes. Only the size budget would notice, and only
# once enough of it had come back. An `absent` line is what makes that a named failure.
# `present` is the other direction, for what must never be trimmed: the SBOM and the
# license texts the packages ship.
set -euo pipefail

cd "$(dirname "$0")/.."

RULES="${RULES:-test/image-files}"

manifests=("$@")
if [ ${#manifests[@]} -eq 0 ]; then
    for f in output/rootfs-files-erofs.txt output/rootfs-files-oci.txt; do
        [ -f "$f" ] && manifests+=("$f")
    done
fi
if [ ${#manifests[@]} -eq 0 ]; then
    echo "error: no manifest in output/ — image/build-rootfs.sh writes one per flavour" >&2
    exit 1
fi

# Every rule, as "kind<TAB>glob<TAB>file:line", so a failure names where it came from.
rules=()
for file in "$RULES"/*.txt; do
    [ -f "$file" ] || continue
    n=0
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        line=${line%%#*}
        read -r kind glob extra <<< "$line" || true
        [ -n "${kind:-}" ] || continue
        case "$kind" in
            absent|present|absent:erofs|absent:oci|present:erofs|present:oci) ;;
            *) echo "error: $file:$n: '$kind' is not absent or present, with :erofs or :oci" >&2
               exit 1 ;;
        esac
        if [ -z "${glob:-}" ] || [ -n "${extra:-}" ]; then
            echo "error: $file:$n: expected '$kind <glob>'" >&2
            exit 1
        fi
        rules+=("$kind"$'\t'"$glob"$'\t'"$file:$n")
    done < "$file"
done
if [ ${#rules[@]} -eq 0 ]; then
    echo "error: no rules in $RULES/*.txt" >&2
    exit 1
fi

status=0
for manifest in "${manifests[@]}"; do
    echo "$manifest"
    flavour=$(sed -n '1s/^# flavour: //p' "$manifest")
    case "$flavour" in
        erofs|oci) ;;
        *) echo "  FAIL: the first line is not '# flavour: erofs' or '# flavour: oci'" >&2
           status=1; continue ;;
    esac
    mapfile -t paths < <(grep -v '^#' "$manifest")
    if [ ${#paths[@]} -eq 0 ]; then
        echo "  FAIL: the manifest is empty" >&2
        status=1
        continue
    fi
    for rule in "${rules[@]}"; do
        IFS=$'\t' read -r kind glob where <<< "$rule"
        case "$kind" in
            *:"$flavour") kind=${kind%:*} ;;
            *:*)          continue ;;
        esac
        matched=()
        for path in "${paths[@]}"; do
            # shellcheck disable=SC2053 # the glob is meant to match
            [[ $path == $glob ]] && matched+=("$path")
        done
        if [ "$kind" = absent ] && [ ${#matched[@]} -gt 0 ]; then
            for path in "${matched[@]}"; do
                echo "  FAIL: /$path is in the $flavour image, and $where says it must not be ($glob)" >&2
            done
            status=1
        elif [ "$kind" = present ] && [ ${#matched[@]} -eq 0 ]; then
            echo "  FAIL: nothing in the $flavour image matches $glob, which $where requires" >&2
            status=1
        fi
    done
done

[ "$status" -eq 0 ] && echo "every image satisfies ${#rules[@]} rules in $RULES/"
exit "$status"
