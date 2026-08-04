#!/usr/bin/env bash
# Put every package's source tarball in downloads/, verified against the checksum in its
# env.sh:
#
#     ./tools/fetch-sources.sh              # all packages
#     ./tools/fetch-sources.sh systemd xz   # just these
#
# build.sh calls this for the one package it is building. Run it with no arguments to
# fetch everything up front, which is the point: after it succeeds nothing else in a
# build needs the network, and the build container is run with --network=none to make
# that true rather than merely intended.
#
# A tarball is only ever accepted if its SHA256 matches. That is what makes a mirror
# safe to fall back to when upstream is unreachable, and what makes an already-present
# file safe to reuse without re-downloading.
set -euo pipefail

cd "$(dirname "$0")/.."

mkdir -p downloads

# A transfer that dies at 80% is the normal failure of a bad link, so resume rather than
# start over — restarting the 150 MB kernel tarball is how a flaky connection turns into
# an infinite loop. --retry-all-errors covers the 5xx a mirror serves while it syncs.
CURL=(curl --location --fail --silent --show-error
      --retry 5 --retry-all-errors --retry-delay 2 --continue-at -)

fetch_one() {
    local pkg="$1"
    local VERSION PACKAGE TARBALL URL SHA256 MIRRORS

    # Subshell would hide the values, so unset what the previous package set instead.
    unset VERSION PACKAGE TARBALL URL SHA256 MIRRORS
    # env.sh may refer to $PKG when composing its URL.
    local PKG="$pkg"
    # shellcheck disable=SC1090
    source "packages/$pkg/env.sh"

    local target="downloads/$TARBALL"

    if [ -z "${SHA256:-}" ]; then
        echo "error: packages/$pkg/env.sh has no SHA256" >&2
        echo "       add one with: sha256sum $target" >&2
        return 1
    fi

    if [ -f "$target" ] && verify "$target" "$SHA256"; then
        echo "  $pkg: $TARBALL already present and verified"
        return 0
    fi

    # A file that is present but wrong is either a half-finished download (which curl
    # will resume onto, producing garbage) or a different file under the same name.
    # Neither is recoverable in place.
    [ -f "$target" ] && { echo "  $pkg: $TARBALL fails its checksum, refetching"; rm -f "$target"; }

    local url
    for url in "$URL" ${MIRRORS:-}; do
        echo "  $pkg: fetching $url"
        if "${CURL[@]}" -o "$target" "$url"; then
            if verify "$target" "$SHA256"; then
                return 0
            fi
            # Not a transport problem: this URL serves the wrong bytes, and retrying it
            # or resuming onto it cannot help. Say so loudly and move to the next source.
            echo "  $pkg: CHECKSUM MISMATCH from $url" >&2
            echo "         expected $SHA256" >&2
            echo "         got      $(sha256sum <"$target" | cut -d' ' -f1)" >&2
            rm -f "$target"
        fi
    done

    echo "error: could not fetch $TARBALL for $pkg from any source" >&2
    return 1
}

verify() {
    [ "$(sha256sum <"$1" | cut -d' ' -f1)" = "$2" ]
}

packages=("$@")
if [ ${#packages[@]} -eq 0 ]; then
    packages=()
    for e in packages/*/env.sh; do packages+=("$(basename "$(dirname "$e")")"); done
fi

failed=()
for pkg in "${packages[@]}"; do
    pkg="${pkg%/}"; pkg="${pkg#packages/}"
    [ -f "packages/$pkg/env.sh" ] || { echo "error: unknown package '$pkg'" >&2; exit 1; }
    # One unreachable upstream should not hide the state of the other 22, so collect the
    # failures and report them together at the end.
    fetch_one "$pkg" || failed+=("$pkg")
done

if [ ${#failed[@]} -gt 0 ]; then
    echo "error: failed to fetch: ${failed[*]}" >&2
    exit 1
fi
