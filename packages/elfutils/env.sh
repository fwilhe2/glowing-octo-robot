VERSION="0.196"
PACKAGE="elfutils-${VERSION}"
TARBALL="$PACKAGE.tar.bz2"
URL="https://sourceware.org/elfutils/ftp/${VERSION}/${TARBALL}"
SHA256="fd5cc6b77ad6773cac93cb3f415f9318ac3b3455eecf801f6b4a742c4f6c7209"
LICENSE="GPL-3.0-or-later AND (LGPL-3.0-or-later OR GPL-2.0-or-later)"
# Here only for libelf.so.1, which libbpf links against.
# The FTP directory holds one subdirectory per release rather than the tarballs
# side by side, so look a level up.
UPSTREAM_INDEX="https://sourceware.org/elfutils/ftp/"
UPSTREAM_SUBDIR="[0-9]+\.[0-9]+/"
