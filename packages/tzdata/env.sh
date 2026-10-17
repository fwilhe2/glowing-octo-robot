# IANA's time zone database, from its git mirror's tags. The release tarballs on
# data.iana.org do not fit build.sh: tzdata/tzcode-*.tar.gz have no top-level directory,
# so --strip-components=1 would throw every file away, and tzdb-*.tar.lz needs lzip on
# the host. The tag archive is the same tree under one tz-<version>/ directory.
#
# TARBALL names the file in downloads/, not the one GitHub serves: the archive is called
# 2026e.tar.gz, which says nothing about what it is in a directory shared by every package.
VERSION="2026e"
PACKAGE="tzdata-${VERSION}"
TARBALL="$PACKAGE.tar.gz"
URL="https://github.com/eggert/tz/archive/refs/tags/${VERSION}.tar.gz"
SHA256="5b62258a9a868813f00b070983b9b3e7279634575571a0fcc732be6a1f7047c1"
# The data and zic are public domain; the BSD-3-Clause files LICENSE names (date.c,
# strftime.c) are neither built nor shipped here.
LICENSE="LicenseRef-PublicDomain"
UPSTREAM_GITHUB="eggert/tz"
# tz numbers releases <year><letter>. That is a final release, not a pre-release, but it
# is not what tools/upstream.sh's default pattern accepts, and widening that pattern for
# everyone would let suffixes through that are pre-releases elsewhere.
UPSTREAM_NUM='[0-9]{4}[a-z]'
