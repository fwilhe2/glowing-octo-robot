# The CLI against the shared library, which is upstream's zstd-dll target and how Debian
# and Fedora both ship it. The default compiles the whole library into the binary a
# second time — 1 MiB of /usr/bin/zstd duplicating the libzstd.so.1 beside it, which
# systemd, kmod, curl and libelf load anyway. ../lib goes first on the link line because
# the builder has a libzstd-dev of its own (for systemd's configure), and the CLI uses
# the experimental API, which must come from the same version that ships. `make install`
# then finds a zstd already built and installs it rather than building the static one.
make lib-release
make -C programs zstd-dll LDFLAGS="-L../lib ${LDFLAGS:-}"
make install PREFIX=/usr DESTDIR=$ROOTFS
readelf -d $ROOTFS/usr/bin/zstd | grep -q 'NEEDED.*libzstd\.so' || {
    echo "zstd: the CLI is not linked against libzstd.so" >&2
    exit 1
}

# zstd has no configure, so the two wrapper scripts come off after the install. They are
# the same case packages/gzip/build.sh and packages/xz/build.sh argue: zstdgrep needs a
# `grep` (which is here) and zstdless needs a `less` (which is not), so shipping the pair
# means shipping one that cannot work.
#
# The `zstd` binary itself stays, and that is a deliberate line rather than an oversight.
# The image ships gzip and xz as usable tools, journald writes its journal in zstd, and a
# person debugging a booted machine who can decompress two of the three formats it uses
# is in a worse position than the 0.2 MiB it costs, linked as above, is worth. unzstd,
# zstdcat and zstdmt stay too — they are argv[0] aliases for the same binary, not
# wrappers.
drop_installed zstdgrep zstdless
