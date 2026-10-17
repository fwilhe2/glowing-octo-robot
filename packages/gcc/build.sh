# gcc is here for its runtime, not as a compiler: the image ships two libraries from this
# build, libgcc_s.so.1 and libstdc++.so.6, and the compiler that made them is thrown
# away. The builder image's gcc stays the toolchain (CLAUDE.md, "No self-hosted
# toolchain").
#
#   libgcc_s     glibc dlopens it by name for pthread_cancel, pthread_exit and
#                backtrace(), and aborts with "libgcc_s.so.1 must be installed for ..."
#                without it. test/check-rootfs-deps.sh cannot see a dlopen, which is how
#                its absence went unnoticed. It is also in the NEEDED of nearly every
#                prebuilt Rust binary for a *-linux-gnu target, for panic unwinding.
#   libstdc++    nothing built here is C++, but a prebuilt binary with any C++ in it —
#                a Rust crate bundling rocksdb or grpc, a cgo Go binary — needs it.
#
# The version is coupled to the builder's gcc, the way packages/openssl is coupled to
# sid's libssl-dev: binaries compiled by Debian's gcc ask for GCC_* and GLIBCXX_* symbol
# versions, so ours have to define at least as many. The check at the bottom of this file
# enforces that; bump this package when builder/Containerfile's snapshot moves gcc.
#
# Only the stage-1 compiler and the two target libraries are built:
#
#   --disable-bootstrap   one pass, with the builder's gcc compiling cc1. The three-stage
#                         bootstrap proves the compiler can rebuild itself, and that
#                         compiler is never shipped.
#   --enable-languages    c++ is what builds libstdc++; c comes with it.
#   --disable-lib*        every other target library. None is wanted, and each would be
#                         compiled only to be deleted.
#   --without-isl, --disable-lto, --disable-plugin
#                         optional features of the discarded compiler.
#   --disable-libstdcxx-pch
#                         precompiled headers, for a compiler that does not exist here.
#
# gcc refuses to build in its source directory, hence build/.
mkdir -p build
cd build

# Two sets of flags, because two compilers are involved. The builder's gcc compiles cc1
# and cc1plus from CFLAGS/CXXFLAGS; the -O2 is explicit because the CFLAGS
# builder/build-package.sh exports is non-empty, so configure does not add its own. The
# new xgcc compiles the target libraries from the _FOR_TARGET variables, which configure
# does not derive from LDFLAGS — so they are passed by hand, or the libraries would be
# linked against the builder image's glibc rather than ours.
../configure \
    --prefix=/usr \
    --libdir=/usr/lib \
    --enable-languages=c,c++ \
    --enable-shared \
    --disable-bootstrap \
    --disable-multilib \
    --disable-nls \
    --disable-lto \
    --disable-plugin \
    --without-isl \
    --disable-libsanitizer \
    --disable-libgomp \
    --disable-libquadmath \
    --disable-libssp \
    --disable-libatomic \
    --disable-libitm \
    --disable-libvtv \
    --disable-libstdcxx-pch \
    CFLAGS="-O2 $CFLAGS" \
    CXXFLAGS="-O2 $CXXFLAGS" \
    CFLAGS_FOR_TARGET="-g -O2 $CPPFLAGS" \
    CXXFLAGS_FOR_TARGET="-g -O2 $CPPFLAGS" \
    LDFLAGS_FOR_TARGET="$LDFLAGS"

make all-gcc
make all-target-libgcc all-target-libstdc++-v3

# Not `make install-target-*`: those install libgcc.a, the crt*.o, gcc's private headers,
# libstdc++'s headers and static archives, and a python gdb pretty-printer next to
# libstdc++.so — inputs to a compiler, and an interpreter script (constraint 5). The
# files a running system can reach are the shared libraries and the SONAME link.
triplet=$(./gcc/xgcc -dumpmachine)
install -D -m 755 "$triplet/libgcc/libgcc_s.so.1" "$ROOTFS/usr/lib/libgcc_s.so.1"
libstdcxx=$(cd "$triplet/libstdc++-v3/src/.libs" && ls libstdc++.so.6.*[0-9])
install -m 755 "$triplet/libstdc++-v3/src/.libs/$libstdcxx" "$ROOTFS/usr/lib/$libstdcxx"
ln -sf "$libstdcxx" "$ROOTFS/usr/lib/libstdc++.so.6"

# Every version node the builder's copy defines, ours must define too. A missing one is
# a binary in the image — or a prebuilt one somebody copies in — asking for a GCC_* or
# GLIBCXX_* version that nothing answers, and failing at exec time.
version_nodes() {
    readelf -V --wide "$1" | sed -n '/Version definition/,/Version needs/s/.*Name: \([^ ]*\).*/\1/p' | sort -u
}
multiarch=$(gcc -print-multiarch)
for lib in libgcc_s.so.1 libstdc++.so.6; do
    missing=$(comm -23 <(version_nodes "/usr/lib/$multiarch/$lib") \
                       <(version_nodes "$ROOTFS/usr/lib/$lib"))
    if [ -n "$missing" ]; then
        echo "error: our $lib lacks version nodes the builder's gcc defines:" $missing >&2
        echo "       packages/gcc has fallen behind builder/Containerfile's gcc" >&2
        exit 1
    fi
done
