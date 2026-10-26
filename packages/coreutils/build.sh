# gnulib's mknod probe refuses to run as root; see packages/tar/build.sh.
export gl_cv_func_mknod_works=yes

# --without-selinux, --without-openssl, --without-libgmp: all three are in the builder
# (Debian's coreutils uses the first two; gmp is gcc's) and none ships, so autodetection
# would link binaries that cannot start. Without them coreutils uses its own hashes and
# gnulib's mini-gmp.
#
# --enable-single-binary=symlinks: one multicall binary, every program a symlink to it —
# 1.5 MiB instead of 6.7 MiB of a hundred copies of gnulib. libstdbuf.so stays separate,
# since stdbuf preloads it into another program.
./configure --prefix=/usr --without-selinux --without-openssl --without-libgmp \
    --enable-single-binary=symlinks
make
make install DESTDIR=$ROOTFS
assert_not_linked libgmp usr/bin/coreutils
[ -L $ROOTFS/usr/bin/ls ] || { echo "coreutils: ls is not a link to the multicall binary" >&2; exit 1; }
