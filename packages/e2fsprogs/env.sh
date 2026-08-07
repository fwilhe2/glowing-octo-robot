VERSION="1.47.4"
PACKAGE="e2fsprogs-${VERSION}"
TARBALL="$PACKAGE.tar.gz"
URL="https://mirrors.edge.kernel.org/pub/linux/kernel/people/tytso/e2fsprogs/v$VERSION/$TARBALL"
SHA256="da274408bebbfd13a5a2fc3cfc66e3ffff17c48534673aa67f88d49b99123b96"
LICENSE="GPL-2.0-only AND LGPL-2.0-only AND BSD-3-Clause AND MIT"
# Tarballs live one directory down, in v1.47.3/.
UPSTREAM_INDEX="https://mirrors.edge.kernel.org/pub/linux/kernel/people/tytso/e2fsprogs/"
UPSTREAM_SUBDIR="v[0-9]+(\.[0-9]+)*/"
