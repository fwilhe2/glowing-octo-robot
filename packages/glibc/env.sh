VERSION="2.44"
PACKAGE="glibc-$VERSION"
TARBALL="$PACKAGE.tar.gz"
URL="https://ftp.fau.de/gnu/glibc/${TARBALL}"
SHA256="1217fc41ac7fb1f310c8c32b9c6c009cc769398d4b367b6aa57be0bb3ea8c1ef"
# glibc is what every other package is then compiled against, so it is the one package
# that has to build against the builder image's own libc.
NO_SYSROOT=1
