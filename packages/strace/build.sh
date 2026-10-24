# Every optional dependency named off. libdw and libunwind are the two stack unwinders
# behind `strace -k`: the base trims libdw (packages/elfutils) and ships no libunwind, so
# either would be a library the extension needs and the machine does not have. libiberty
# only demangles those stacks. libselinux is the trap CLAUDE.md describes for iproute2 —
# libblkid-dev pulls its headers into the builder, and strace would decode SELinux
# contexts against a library nothing ships.
#
# --enable-mpers=no: the "multiple personalities" are decoders for 32-bit processes on a
# 64-bit kernel, which need a multilib compiler the builder does not have and binaries
# this image does not run.
./configure \
    --prefix=/usr \
    --enable-mpers=no \
    --without-libdw \
    --without-libunwind \
    --without-libiberty \
    --without-libselinux \
    --disable-gcc-Werror
make
# Only the binary. strace-log-merge is a shell script for -ff output, and would be fine
# here; it is left out because `sort -m` over the files does the same.
install -D -m 755 src/strace $ROOTFS/usr/bin/strace
