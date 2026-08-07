VERSION="0.195"
PACKAGE="elfutils-${VERSION}"
TARBALL="$PACKAGE.tar.bz2"
URL="https://sourceware.org/elfutils/ftp/${VERSION}/${TARBALL}"
SHA256="37629fdf7f1f3dc2818e138fca2b8094177d6c2d0f701d3bb650a561218dc026"
LICENSE="GPL-3.0-or-later AND (LGPL-3.0-or-later OR GPL-2.0-or-later)"
# Here only for libelf.so.1, which libbpf links against.
# The FTP directory holds one subdirectory per release rather than the tarballs
# side by side, so look a level up.
UPSTREAM_INDEX="https://sourceware.org/elfutils/ftp/"
UPSTREAM_SUBDIR="[0-9]+\.[0-9]+/"
