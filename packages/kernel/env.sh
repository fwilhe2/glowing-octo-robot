VERSION="7.2.6"
PACKAGE="linux-${VERSION}"
TARBALL="$PACKAGE.tar.xz"
URL="https://cdn.kernel.org/pub/linux/kernel/v${VERSION%%.*}.x/${TARBALL}"
SHA256="039aef84f2b0994aeda3f4fcfc3d02ec9d7a9bbb9020ea264c43f446c860f606"
LICENSE="GPL-2.0-only WITH Linux-syscall-note"
# Debian's linux source package pulls in a whole distro kernel toolchain (and its
# build-dep list breaks whenever sid moves), so list what this build actually needs.
# The kernel is freestanding — it links against no libc at all, and kbuild builds its
# host tools with the builder's own headers — so there is nothing to point at a sysroot.
NO_SYSROOT=1
# Each major series has its own directory, and $URL only ever points into the one the
# pinned version belongs to — so look a level up, or 7.x would stay invisible forever
# to a pin in 6.x. Release candidates are filed separately under v7.x/testing/.
UPSTREAM_INDEX="https://cdn.kernel.org/pub/linux/kernel/"
UPSTREAM_SUBDIR="v[0-9]+\.x/"
