VERSION="2.44"
PACKAGE="glibc-$VERSION"
TARBALL="$PACKAGE.tar.gz"
URL="https://ftp.fau.de/gnu/glibc/${TARBALL}"
SHA256="1217fc41ac7fb1f310c8c32b9c6c009cc769398d4b367b6aa57be0bb3ea8c1ef"
LICENSE="LGPL-2.1-or-later AND GPL-2.0-or-later"
# glibc is what every other package is then compiled against, so it is the one package
# that has to build against the builder image's own libc.
NO_SYSROOT=1
# ...and the one package that *fills* the sysroot, so it installs into that tree rather
# than into rootfs/, and build.sh mirrors the result into rootfs/ afterwards. Everything
# else compiles against what this leaves behind, and against nothing else of ours: a
# sysroot that were the cumulative staging tree would hand each package the headers and
# libraries of every package built before it. See build.sh, where SYSROOT_DIR is set.
FILLS_SYSROOT=1
