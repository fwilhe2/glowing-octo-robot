make
make install PREFIX=/usr DESTDIR=/usr/local/rootfs

# zstd has no configure, so the two wrapper scripts come off after the install. They are
# the same case packages/gzip/build.sh and packages/xz/build.sh argue: zstdgrep needs a
# `grep` (which is here) and zstdless needs a `less` (which is not), so shipping the pair
# means shipping one that cannot work.
#
# The `zstd` binary itself stays, and that is a deliberate line rather than an oversight.
# The image ships gzip and xz as usable tools, journald writes its journal in zstd, and a
# person debugging a booted machine who can decompress two of the three formats it uses
# is in a worse position than the 1.9 MiB is worth. unzstd, zstdcat and zstdmt stay too —
# they are argv[0] aliases for the same binary, not wrappers.
for prog in zstdgrep zstdless; do
    if [ ! -e "/usr/local/rootfs/usr/bin/$prog" ]; then
        echo "zstd: $prog is not installed — this removal list is stale" >&2
        exit 1
    fi
    rm -f "/usr/local/rootfs/usr/bin/$prog"
done
