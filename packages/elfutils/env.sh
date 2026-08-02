VERSION="0.195"
PACKAGE="elfutils-${VERSION}"
TARBALL="$PACKAGE.tar.bz2"
URL="https://sourceware.org/elfutils/ftp/${VERSION}/${TARBALL}"
# Here only for libelf.so.1, which libbpf links against. Debian's source package is
# `elfutils`, so the default BUILD_DEP is right; it does not pull the zstd headers the
# configure below asks for.
EXTRA_DEPS="libzstd-dev"
# The FTP directory holds one subdirectory per release rather than the tarballs
# side by side, so look a level up.
UPSTREAM_INDEX="https://sourceware.org/elfutils/ftp/"
UPSTREAM_SUBDIR="[0-9]+\.[0-9]+/"
