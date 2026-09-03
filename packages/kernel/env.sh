VERSION="7.2.3"
PACKAGE="linux-${VERSION}"
TARBALL="$PACKAGE.tar.xz"
URL="https://cdn.kernel.org/pub/linux/kernel/v${VERSION%%.*}.x/${TARBALL}"
SHA256="8ba259e8e7b13ec6ef0941c8a39ad90b24bd4a4d6c0010ba6bafb794550ecd03"
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
