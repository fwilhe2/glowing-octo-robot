#!/bin/bash
# Report binaries that call a function none of the libraries they load defines.
#
# The third of the library checks, and the one that holds the builder coupling to
# account (docs/guides/linking.md). test/check-rootfs-deps.sh asks "is libfoo.so.N in the tree?",
# test/check-symbol-versions.sh asks "does it define the symbol *versions* the binary
# wants?" — and that second question only exists for libraries that version their
# symbols. glib, json-c, pcre2, jansson and libnftnl do not: a binary compiled against
# sid's newer header for one of them names a plain `g_foo`, which nothing can hold
# against a version, and the first sign is
#
#     conmon: symbol lookup error: conmon: undefined symbol: g_foo
#
# at exec time, or later still — symbols are bound lazily, so only when that code path
# first runs. This asks the question directly: for every undefined symbol in every ELF
# object, is it defined somewhere in that object's NEEDED closure (itself, what it
# needs, what those need, ...)?
#
# Versions are ignored here, that being the other check's job, and so are *weak*
# undefined symbols, which are allowed to stay unresolved: that is how a library asks
# "is this optional function present?" and gets NULL when it is not.
#
# Some objects resolve symbols from outside their own NEEDED closure, legitimately:
# plugins expect the program that dlopens them to provide symbols (bash's loadable
# builtins call bash's own functions). Those are not missing libraries and not skew, so
# test/known-unresolved-symbols.txt lists them, by SONAME, the way
# test/known-missing-libs.txt lists the library backlog. An object whose NEEDED names a
# library the tree does not ship is test/check-rootfs-deps.sh's business and skipped.
#
#     ./test/check-symbol-resolution.sh [rootfs-dir]
set -euo pipefail

ROOT="${1:-rootfs}"
ALLOW="$(dirname "$0")/known-unresolved-symbols.txt"

if [ ! -d "$ROOT" ]; then
    echo "error: no such directory: $ROOT" >&2
    exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export work

# One readelf pass, parallel, one dump file per worker — as in check-symbol-versions.sh,
# and for the same reason. -d for NEEDED and SONAME, --dyn-syms for the symbols: the
# dynamic symbol table, not the full one, because it is the only one the loader reads
# and the only one a stripped binary keeps.
find "$ROOT" -type f -print0 \
    | xargs -0 -P "$(nproc)" -n 40 sh -c '
        for f in "$@"; do
            printf "===FILE=== %s\n" "$f"
            readelf -dW --dyn-syms "$f" 2>/dev/null
        done >> "$work/dump.$$"' _ || true

# The loader resolves a NEEDED entry by *file name*, not by SONAME, so a symlink is as
# good a provider as the library's own name: bash asks for libtinfo.so.6, which is a link
# to ncurses' libtinfow.so.6, whose SONAME says libtinfow. Every link's name and its
# target's name go in too, as check-rootfs-deps.sh counts them.
find "$ROOT" -type l -printf '===LINK=== %f %l\n' > "$work/links"

# Allowlist entries are "<soname> <symbol>", # comments — the SONAME rather than a path,
# so an entry holds wherever the library is found. An object with no SONAME, a plugin or
# a program, is named by its file name.
allow=$work/allow
if [ -f "$ALLOW" ]; then
    sed 's/#.*//' "$ALLOW" | awk 'NF == 2' > "$allow"
else
    : > "$allow"
fi

# Two passes in one awk. Reading: each file's SONAME (its basename when it has none),
# NEEDED list, defined and undefined symbols. Then, for every file with undefined
# symbols, walk its NEEDED closure breadth-first and report the ones nothing in it
# defines. A row of readelf's symbol table is
#
#     Num: Value Size Type Bind Vis Ndx Name [(version index)]
#
# Ndx is UND for an undefined symbol, a section number or ABS for a defined one; the
# name carries @VERSION or @@VERSION, which is stripped.
cat "$work/links" "$work"/dump.* 2>/dev/null | awk -v root="$ROOT/" -v allowfile="$allow" '
    BEGIN {
        while ((getline line < allowfile) > 0) {
            split(line, a, " ")
            allowed[a[1] SUBSEP a[2]] = 1
        }
    }
    $1 == "===LINK===" {
        t = $3; sub(/.*\//, "", t)
        nlinks++; link_name[nlinks] = $2; link_target[nlinks] = t
        next
    }
    $1 == "===FILE===" {
        file = $2
        base = file; sub(/.*\//, "", base)
        soname_of[file] = base
        nfiles++; files[nfiles] = file
        insyms = 0
        next
    }
    /\(SONAME\)/ {
        s = $0; sub(/.*\[/, "", s); sub(/\].*/, "", s)
        soname_of[file] = s
        next
    }
    /\(NEEDED\)/ {
        s = $0; sub(/.*\[/, "", s); sub(/\].*/, "", s)
        nneed[file]++; need[file, nneed[file]] = s
        next
    }
    /^Symbol table .\.dynsym./ { insyms = 1; elf[file] = 1; next }
    insyms && $1 ~ /^[0-9]+:$/ && NF >= 8 {
        bind = $5; ndx = $7; name = $8
        sub(/@.*/, "", name)
        if (name == "") next
        if (ndx == "UND") {
            if (bind == "WEAK") next
            nund[file]++; und[file, nund[file]] = name
        } else {
            defs[file, name] = 1
        }
        next
    }
    END {
        # SONAME -> a file that has it. Several can (the same library under two names is
        # a symlink, and -type f sees only one); any of them defines the same symbols.
        for (i = 1; i <= nfiles; i++) {
            f = files[i]
            if (!elf[f]) continue
            if (!(soname_of[f] in lib_of)) lib_of[soname_of[f]] = f
            b = f; sub(/.*\//, "", b)
            if (!(b in lib_of)) lib_of[b] = f
        }
        # Then the links, followed name by name until nothing changes: libtinfo.so.6
        # reaches a file only through libtinfow.so.6.
        do {
            changed = 0
            for (i = 1; i <= nlinks; i++)
                if (!(link_name[i] in lib_of) && (link_target[i] in lib_of)) {
                    lib_of[link_name[i]] = lib_of[link_target[i]]; changed = 1
                }
        } while (changed)
        for (i = 1; i <= nfiles; i++) {
            f = files[i]
            if (!nund[f]) continue
            # The closure, as a queue of files. A NEEDED the tree does not ship ends the
            # check for this object: it cannot be judged, and check-rootfs-deps says so.
            delete seen; q = 1; n = 1; queue[1] = f; seen[f] = 1; incomplete = 0
            while (q <= n) {
                g = queue[q++]
                for (j = 1; j <= nneed[g]; j++) {
                    s = need[g, j]
                    if (!(s in lib_of)) { incomplete = 1; continue }
                    h = lib_of[s]
                    if (!(h in seen)) { seen[h] = 1; queue[++n] = h }
                }
            }
            rel = f; sub("^" root, "", rel)
            if (incomplete) { print "SKIP\t" rel; continue }
            for (k = 1; k <= nund[f]; k++) {
                sym = und[f, k]
                found = 0
                for (m = 1; m <= n; m++) if (defs[queue[m], sym]) { found = 1; break }
                if (!found && !allowed[soname_of[f], sym]) print rel "\t" sym
            }
        }
    }' | sort -u > "$work/result"

grep -v '^SKIP' "$work/result" > "$work/unresolved" || true
skipped=$(grep -c '^SKIP' "$work/result" || true)
# Said every time, pass or fail, so that a backlog in known-missing-libs.txt is never
# mistaken for coverage: those objects were not checked at all.
if [ "$skipped" -gt 0 ]; then
    echo "note: $skipped object(s) need a library $ROOT/ does not ship and were not checked;"
    echo "      test/check-rootfs-deps.sh reports which."
fi

if [ ! -s "$work/unresolved" ]; then
    echo "Every symbol an object in $ROOT/ uses is defined by the libraries it loads."
    exit 0
fi

echo "UNRESOLVED symbols in $ROOT/:"
echo
cut -f1 "$work/unresolved" | uniq | while read -r obj; do
    printf '  %s\n' "$obj"
    awk -F'\t' -v o="$obj" '$1 == o { print $2 }' "$work/unresolved" > "$work/syms"
    head -6 "$work/syms" | sed 's/^/      /'
    n=$(wc -l < "$work/syms")
    if [ "$n" -gt 6 ]; then
        printf '      ... and %s more\n' "$((n - 6))"
    fi
done
echo
echo "Each of these calls a function that no library in its NEEDED closure defines, and"
echo "will fail with 'undefined symbol' when the call is first made. The usual cause is a"
echo "header from builder/deps.txt newer than the library packages/ ships: bump ours to"
echo "at least sid's (docs/guides/linking.md). A plugin that expects its host program to"
echo "provide the symbol is not a bug; add it to test/known-unresolved-symbols.txt."
exit 1
