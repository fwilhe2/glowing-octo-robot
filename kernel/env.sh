VERSION="6.12.96"
PACKAGE="linux-${VERSION}"
TARBALL="$PACKAGE.tar.xz"
URL="https://cdn.kernel.org/pub/linux/kernel/v${VERSION%%.*}.x/${TARBALL}"
# Debian's linux source package pulls in a whole distro kernel toolchain (and its
# build-dep list breaks whenever sid moves), so list what this build actually needs.
BUILD_DEP=""
EXTRA_DEPS="bc bison flex libelf-dev libssl-dev dwarves rsync cpio kmod zstd"
