# Built for libgcc_s.so.1 and libstdc++.so.6 only; packages/gcc/build.sh says why, and
# why the compiler it builds is thrown away.
#
# The version is not ours to choose: it has to match the builder image's gcc, which
# builder/Containerfile's snapshot date pins (16.2.0 at 20260918). Debian's gcc emits
# references to the GCC_* and GLIBCXX_* version nodes its own runtime defines, and it is
# our runtime that answers at exec time — so ours may not be older, and build.sh fails
# when it is. Newer within the same major is safe; a new major means a new libstdc++
# ABI generation and waits for sid.
VERSION="16.2.0"
PACKAGE="gcc-${VERSION}"
TARBALL="$PACKAGE.tar.xz"
URL="https://ftp.fau.de/gnu/gcc/${PACKAGE}/${TARBALL}"
MIRRORS="https://ftp.gnu.org/gnu/gcc/${PACKAGE}/${TARBALL}"
SHA256="e6738e29597f733270731aa90600f37ffdc045079dfc27ec7e8192cc81085c3e"
# Only libgcc and libstdc++ ship, and both carry the runtime library exception.
LICENSE="GPL-3.0-or-later WITH GCC-exception-3.1"
# Releases live one directory per version, so the listing to scrape is the parent.
UPSTREAM_INDEX="https://ftp.fau.de/gnu/gcc/"
UPSTREAM_REGEX='gcc-([0-9]+(\.[0-9]+)*)/'
# Every major but 16 — the line to edit when builder/Containerfile's snapshot moves sid
# to a new gcc.
UPSTREAM_IGNORE='([0-9]|1[0-57-9]|[2-9][0-9])\..*'
