#!/bin/bash
# Report shared libraries that binaries in the rootfs need but the rootfs doesn't ship.
#
# Every package is compiled inside the Debian builder image, so a build will happily
# link against a library that exists only in that container: the build succeeds, the
# library is never staged, and nothing notices until the binary is exec'd in qemu.
# That is how bash ended up needing libtinfo.so.6 with no ncurses package. This walks
# the assembled tree and reports every unresolved NEEDED entry at once.
#
#     ./test/check-rootfs-deps.sh [rootfs-dir] [allowlist]
#
# Libraries listed in test/known-missing-libs.txt are reported but don't fail the run, so
# this catches new regressions without being blocked on the existing backlog.
set -euo pipefail

ROOT="${1:-rootfs}"
ALLOWLIST="${2:-$(dirname "$0")/known-missing-libs.txt}"

if [ ! -d "$ROOT" ]; then
    echo "error: no such directory: $ROOT" >&2
    exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# One readelf pass over the whole tree, in parallel — the tree is ~6k files and doing
# this per-library instead is quadratic and takes minutes.
find "$ROOT" -type f -print0 \
    | xargs -0 -P "$(nproc)" -n 40 sh -c '
        for f in "$@"; do
            readelf -d "$f" 2>/dev/null \
                | sed -n "s/.*NEEDED.*\[\(.*\)\].*/\1/p" \
                | sed "s|\$|\t$f|"
        done' _ > "$work/pairs" || true

cut -f1 "$work/pairs" | sort -u > "$work/needed"

# What the tree ships: each library's SONAME, plus its bare filename — a few libraries
# carry no SONAME and the loader resolves those by name via ld.so.conf.
find "$ROOT" -name '*.so*' \( -type f -o -type l \) -print0 \
    | xargs -0 -P "$(nproc)" -n 40 sh -c '
        for f in "$@"; do
            basename "$f"
            readelf -d "$f" 2>/dev/null | sed -n "s/.*SONAME.*\[\(.*\)\].*/\1/p"
        done' _ | sort -u > "$work/provided"

comm -13 "$work/provided" "$work/needed" > "$work/missing"

if [ ! -s "$work/missing" ]; then
    echo "All shared library dependencies in $ROOT/ are satisfied."
    exit 0
fi

if [ -f "$ALLOWLIST" ]; then
    grep -v '^\s*\(#\|$\)' "$ALLOWLIST" | sort -u > "$work/allowed"
else
    : > "$work/allowed"
fi

comm -13 "$work/allowed" "$work/missing" > "$work/new"
comm -12 "$work/allowed" "$work/missing" > "$work/known"

report() {
    while IFS= read -r lib; do
        printf '  %s\n' "$lib"
        awk -F'\t' -v l="$lib" '$1==l{print $2}' "$work/pairs" \
            | sed "s|^$ROOT/||" | sort | head -4 | sed 's/^/      needed by /'
        local n
        n=$(awk -F'\t' -v l="$lib" '$1==l' "$work/pairs" | wc -l)
        if [ "$n" -gt 4 ]; then
            printf '      ... and %s more\n' "$((n - 4))"
        fi
    done < "$1"
}

if [ -s "$work/known" ]; then
    echo "Known-missing libraries (listed in $(basename "$ALLOWLIST")):"
    report "$work/known"
    echo
fi

if [ -s "$work/new" ]; then
    echo "NEW unresolved shared library dependencies in $ROOT/:"
    echo
    report "$work/new"
    echo
    echo "Each is linked against a library from the Debian builder image that is never"
    echo "installed into the rootfs. Either add a package providing it, or configure the"
    echo "package that wants it to build without that optional dependency."
    exit 1
fi

echo "No new unresolved dependencies."
