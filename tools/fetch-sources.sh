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
source tools/lib.sh

mkdir -p downloads

# A transfer that dies at 80% is the normal failure of a bad link, so resume rather than
# start over — restarting the 150 MB kernel tarball is how a flaky connection turns into
# an infinite loop.
CURL=("${CURL_DOWNLOAD[@]}" --continue-at -)

# Run in a subshell (see the loop below), so one package's env.sh cannot leak into the
# next — an unset list kept by hand here used to be what prevented that.
fetch_one() {
    local pkg="$1"
    load_env "$pkg"

    # A package whose source is in this repository has no tarball and no checksum, so
    # there is nothing here to fetch or verify. It is still a package everywhere else.
    if [ -n "${LOCAL_SOURCE:-}" ]; then
        echo "  $pkg: source is in this repository, nothing to fetch"
        return 0
    fi

    local target="downloads/$TARBALL"

    if [ -z "${SHA256:-}" ]; then
        echo "error: packages/$pkg/env.sh has no SHA256" >&2
        echo "       add one with: sha256sum $target" >&2
        return 1
    fi

    if [ -f "$target" ] && verify "$target" "$SHA256"; then
        echo "  $pkg: $TARBALL already present and verified"
        fetch_crates "$pkg" "$target"
        return
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
                fetch_crates "$pkg" "$target"
                return
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

# A Rust package's crates, which the compile cannot fetch for itself — it runs
# --network=none like every other. CARGO_CRATES=1 in env.sh asks for this. The list is the
# Cargo.lock inside the tarball just verified, and each crate is checked against the
# sha256 that lock records, so the chain of custody is the same as for the tarball: the
# pin in env.sh covers Cargo.lock, and Cargo.lock covers every crate. A version bump
# brings its own set with no further edit.
#
# One directory for every package's crates, named the way crates.io names them, so two
# packages that lock the same crate share one file. Like downloads/ itself it is
# cumulative; tools/prep.sh copies only the crates the current locks name into the
# sources image.
fetch_crates() {
    local pkg="$1" tarball="$2" name ver sum file n=0
    [ -n "${CARGO_CRATES:-}" ] || return 0
    mkdir -p downloads/crates
    while read -r name ver sum; do
        file="downloads/crates/$name-$ver.crate"
        if [ -f "$file" ] && verify "$file" "$sum"; then
            continue
        fi
        rm -f "$file"
        if ! "${CURL_DOWNLOAD[@]}" -o "$file" "https://static.crates.io/crates/$name/$name-$ver.crate"; then
            echo "error: $pkg: could not fetch crate $name $ver" >&2
            return 1
        fi
        if ! verify "$file" "$sum"; then
            echo "  $pkg: CHECKSUM MISMATCH for crate $name $ver" >&2
            echo "         expected $sum (from Cargo.lock)" >&2
            echo "         got      $(sha256sum <"$file" | cut -d' ' -f1)" >&2
            rm -f "$file"
            return 1
        fi
        n=$((n + 1))
    done < <(cargo_lock "$tarball" | cargo_lock_crates)
    # The process substitution's own exit status is invisible to the loop, so a lock the
    # reader refused (a git dependency) has to be checked separately.
    cargo_lock "$tarball" | cargo_lock_crates >/dev/null
    echo "  $pkg: crates verified ($n fetched)"
}

verify() {
    [ "$(sha256sum <"$1" | cut -d' ' -f1)" = "$2" ]
}

packages=("$@")
if [ ${#packages[@]} -eq 0 ]; then
    mapfile -t packages < <(all_packages)
fi

failed=()
for pkg in "${packages[@]}"; do
    pkg=$(package_name "$pkg")
    # One unreachable upstream should not hide the state of the other 22, so collect the
    # failures and report them together at the end.
    ( fetch_one "$pkg" ) || failed+=("$pkg")
done

if [ ${#failed[@]} -gt 0 ]; then
    echo "error: failed to fetch: ${failed[*]}" >&2
    exit 1
fi
