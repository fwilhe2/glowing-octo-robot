# gcc for its runtime only: libgcc_s.so.1 (glibc dlopens it for pthread_cancel and
# backtrace; nearly every prebuilt Rust binary needs it) and libstdc++.so.6 (any prebuilt
# binary with C++ in it). The compiler is thrown away; the builder's stays the toolchain.
#
# Coupled to the builder's gcc: ours must define every GCC_*/GLIBCXX_* version node
# Debian's does, checked at the end. Bump this when the builder snapshot moves gcc.
#
# One pass (no bootstrap), C++ for libstdc++, every other target library and optional
# compiler feature off.
mkdir -p build
cd build

# Two compilers: the builder's gcc builds cc1 from CFLAGS, and the new xgcc builds the
# target libraries from the _FOR_TARGET variables, which do not inherit LDFLAGS — so the
# sysroot is passed by hand, or the libraries would link the builder's glibc.
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

# Just the shared libraries: install-target-* adds compiler inputs and a python gdb
# script (constraint 5).
triplet=$(./gcc/xgcc -dumpmachine)
install -D -m 755 "$triplet/libgcc/libgcc_s.so.1" "$ROOTFS/usr/lib/libgcc_s.so.1"
libstdcxx=$(cd "$triplet/libstdc++-v3/src/.libs" && ls libstdc++.so.6.*[0-9])
install -m 755 "$triplet/libstdc++-v3/src/.libs/$libstdcxx" "$ROOTFS/usr/lib/$libstdcxx"
ln -sf "$libstdcxx" "$ROOTFS/usr/lib/libstdc++.so.6"

# Every version node the builder's copy defines, ours must too, or a binary it compiled
# fails at exec.
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
