#!/bin/bash
# Report binaries that require a symbol version none of the libraries we ship define.
#
# test/check-rootfs-deps.sh answers "is libfoo.so.N in the tree at all?". This answers the
# next question: the binary found the library, but does that library actually have the
# symbols it wants? Versioned symbols are how glibc keeps old binaries working, so a
# binary compiled against a newer libc than the one we ship links fine in the builder
# and then dies at exec time with
#
#     ./ls: /lib64/libc.so.6: version `GLIBC_2.44' not found (required by ./ls)
#
# which is exactly the failure mode of compiling against the builder image's glibc
# instead of ours (issue #33). Requirements on libraries the tree doesn't ship at all
# are test/check-rootfs-deps.sh's business and ignored here.
#
#     ./test/check-symbol-versions.sh [rootfs-dir]
set -euo pipefail

ROOT="${1:-rootfs}"

if [ ! -d "$ROOT" ]; then
    echo "error: no such directory: $ROOT" >&2
    exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export work

# One readelf pass over the whole tree, in parallel, dumped verbatim for the awk below
# to parse. Each worker writes its own file: several thousand multi-line dumps racing
# for one pipe would interleave, and a version entry that lands under the wrong header
# is worse than useless.
find "$ROOT" -type f -print0 \
    | xargs -0 -P "$(nproc)" -n 40 sh -c '
        for f in "$@"; do
            printf "===FILE=== %s\n" "$f"
            readelf -dV "$f" 2>/dev/null
        done >> "$work/dump.$$"' _ || true

# What each library defines (P), and what each binary asks its libraries for (N).
# readelf prints the dynamic section before the version sections, so the SONAME of a
# library is always known by the time its definitions show up.
cat "$work"/dump.* 2>/dev/null | awk '
    $1 == "===FILE===" {
        file = $2
        soname = file
        sub(/.*\//, "", soname)
        mode = ""
        next
    }
    /\(SONAME\)/ {
        soname = $0
        sub(/.*\[/, "", soname)
        sub(/\].*/, "", soname)
        next
    }
    /Version definition section/ { mode = "def";  next }
    /Version needs section/      { mode = "need"; next }
    /Version symbols section/    { mode = "";     next }
    mode != "" {
        for (i = 1; i <= NF; i++) {
            if ($i == "File:") lib = $(i + 1)
            else if ($i == "Name:") {
                if (mode == "def")  print "P\t" soname "\t" $(i + 1)
                if (mode == "need") print "N\t" lib "\t" $(i + 1) "\t" file
            }
        }
    }' > "$work/versions"

awk -F'\t' '$1 == "P" { print $2 "\t" $3 }' "$work/versions" | sort -u > "$work/provided"
awk -F'\t' '$1 == "N" { print $2 "\t" $3 "\t" $4 }' "$work/versions" | sort -u > "$work/needed"

# A library the tree doesn't ship can't be checked here — test/check-rootfs-deps.sh reports
# those — so only requirements on libraries we do ship are held against it.
awk -F'\t' '
    NR == FNR { defines[$1 "\t" $2] = 1; shipped[$1] = 1; next }
    shipped[$1] && !defines[$1 "\t" $2]
' "$work/provided" "$work/needed" > "$work/unsatisfied"

if [ ! -s "$work/unsatisfied" ]; then
    echo "All symbol versions required in $ROOT/ are defined by the libraries it ships."
    exit 0
fi

echo "MISSING symbol versions in $ROOT/:"
echo

cut -f1,2 "$work/unsatisfied" | sort -u | while IFS=$'\t' read -r lib version; do
    printf '  %s: %s\n' "$lib" "$version"
    awk -F'\t' -v l="$lib" -v v="$version" '$1 == l && $2 == v { print $3 }' "$work/unsatisfied" \
        | sed "s|^$ROOT/||" | sort > "$work/consumers"
    head -4 "$work/consumers" | sed 's/^/      needed by /'
    n=$(wc -l < "$work/consumers")
    if [ "$n" -gt 4 ]; then
        printf '      ... and %s more\n' "$((n - 4))"
    fi
done

echo
echo "These binaries were compiled against a newer library than the image ships and will"
echo "fail at exec time. For glibc that means the build didn't go through our sysroot:"
echo "check that SYSROOT reaches the compiler (builder/build-package.sh) and that the"
echo "package's build system doesn't drop the CFLAGS/LDFLAGS it exports."
exit 1
