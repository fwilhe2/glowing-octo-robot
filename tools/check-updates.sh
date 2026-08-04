#!/bin/bash
# Compare the version each package is pinned to against what upstream has released:
#
#     ./tools/check-updates.sh              # every package
#     ./tools/check-updates.sh bash glibc   # only these
#     ./tools/check-updates.sh --json       # machine-readable, for the update workflow
#
# Where to look for versions is declared per package in its env.sh; see tools/upstream.sh.
# A candidate is only reported once its tarball has been confirmed to exist at the URL
# env.sh would download it from, so a project that changes its file naming shows up as
# an error here instead of as a pull request that fails to build.
set -euo pipefail

cd "$(dirname "$0")/.."

JSON=false
PACKAGES=()

for arg in "$@"; do
    case "$arg" in
        --json) JSON=true ;;
        -h|--help) sed -n '2,11p' "$0" | sed 's/^# \?//'; exit 0 ;;
        -*) echo "error: unknown option: $arg" >&2; exit 1 ;;
        # Accept both `coreutils` and the path a shell tab-completes to.
        *) arg="${arg%/}"; PACKAGES+=("${arg#packages/}") ;;
    esac
done

if [ ${#PACKAGES[@]} -eq 0 ]; then
    for e in packages/*/env.sh; do PACKAGES+=("$(basename "$(dirname "$e")")"); done
fi

# The URL a package would download if its env.sh said VERSION=$2. env.sh derives
# PACKAGE, TARBALL and URL from VERSION, so rewriting that one line is all an update
# ever has to do — both here and in the pull request the workflow opens.
url_for_version() (
    PKG="$1"
    eval "$(sed -E "s/^VERSION=.*/VERSION=\"$2\"/" "packages/$PKG/env.sh")"
    printf '%s\n' "$URL"
)

updates=()
failed=false

for PKG in "${PACKAGES[@]}"; do
    if [ ! -f "packages/$PKG/env.sh" ]; then
        echo "error: unknown package '$PKG' (no packages/$PKG/env.sh)" >&2
        failed=true
        continue
    fi

    current=$(source "packages/$PKG/env.sh"; printf '%s\n' "$VERSION")

    # A package whose source is in this repository has no upstream to compare against —
    # its VERSION is ours, and nothing announces releases of it.
    if [ -n "$(source "packages/$PKG/env.sh"; printf '%s' "${LOCAL_SOURCE:-}")" ]; then
        $JSON || printf '%-12s %-10s local source, no upstream\n' "$PKG" "$current"
        continue
    fi

    if ! latest=$(./tools/upstream.sh "$PKG"); then
        $JSON || printf '%-12s %-10s %s\n' "$PKG" "$current" "ERROR: upstream lookup failed"
        failed=true
        continue
    fi

    # sort -V, so 2.10 counts as newer than 2.9 and a downgrade is never proposed.
    if [ "$latest" = "$current" ] || [ "$(printf '%s\n%s\n' "$current" "$latest" | sort -V | tail -1)" = "$current" ]; then
        $JSON || printf '%-12s %-10s up to date\n' "$PKG" "$current"
        continue
    fi

    url=$(url_for_version "$PKG" "$latest")

    if ! curl -fsIL --max-time 60 --retry 2 -o /dev/null "$url"; then
        $JSON || printf '%-12s %-10s %s\n' "$PKG" "$current" "ERROR: $latest announced but $url is not downloadable"
        failed=true
        continue
    fi

    $JSON || printf '%-12s %-10s -> %-10s %s\n' "$PKG" "$current" "$latest" "$url"
    updates+=("$(jq -nc --arg p "$PKG" --arg c "$current" --arg l "$latest" --arg u "$url" \
        '{package:$p, current:$c, latest:$l, url:$u}')")
done

if $JSON; then
    if [ ${#updates[@]} -eq 0 ]; then
        echo '[]'
    else
        printf '%s\n' "${updates[@]}" | jq -sc .
    fi
fi

if $failed; then
    exit 1
fi
