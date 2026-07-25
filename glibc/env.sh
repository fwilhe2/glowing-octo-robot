VERSION="2.44"
PACKAGE="glibc-$VERSION"
TARBALL="$PACKAGE.tar.gz"
URL="https://ftp.fau.de/gnu/glibc/${TARBALL}"
# glibc is what every other package is then compiled against, so it is the one package
# that has to build against the builder image's own libc.
NO_SYSROOT=1
