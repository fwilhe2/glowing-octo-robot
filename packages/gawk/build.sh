# gawk is the awk here because constraint 1 makes it one: mawk and busybox awk are the
# alternatives and both are substitutions of the GNU stack. `make install` creates the
# /usr/bin/awk symlink itself, in its install-exec-hook, so nothing extra is needed to
# make `awk` resolve.
#
# --disable-mpfr: gawk -M does arbitrary-precision arithmetic through libmpfr and
# libgmp. Both -dev packages are in builder/deps.txt, for packages/gcc, and neither
# library is in the image — so this is pinned rather than left to autodetection, which
# would link gawk against both.
#
# --with-readline=no: same story for libreadline, which gawk uses only for line editing
# in its debugger. libreadline.so.8 is already a known-missing-lib (util-linux fdisk).
./configure --prefix=/usr --disable-mpfr --with-readline=no
make
make install DESTDIR=$ROOTFS
