# gawk is the awk here because constraint 1 makes it one: mawk and busybox awk are the
# alternatives and both are substitutions of the GNU stack. `make install` creates the
# /usr/bin/awk symlink itself, in its install-exec-hook, so nothing extra is needed to
# make `awk` resolve.
#
# --disable-mpfr: gawk -M does arbitrary-precision arithmetic through libmpfr and
# libgmp. Neither libmpfr-dev nor libgmp3-dev is in builder/deps.txt — libgmp is
# already on the known-missing-libs backlog from coreutils — so this is pinned rather
# than left to autodetection, which would link gawk against them the day something else
# needs those headers.
#
# --with-readline=no: same story for libreadline, which gawk uses only for line editing
# in its debugger. libreadline.so.8 is already a known-missing-lib (util-linux fdisk).
./configure --prefix=/usr --disable-mpfr --with-readline=no
make
make install DESTDIR=/usr/local/rootfs
