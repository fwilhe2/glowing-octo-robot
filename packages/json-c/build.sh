# Here for crun, which parses config.json with it (PKG_CHECK_MODULES json-c >= 0.14).
# crun used to bundle yajl and could be built --enable-embedded-yajl; since it moved to
# json-c there is no embedded option left, so the library has to be a package.
#
# CMAKE_INSTALL_LIBDIR=lib: GNUInstallDirs on Debian resolves libdir to the multiarch
# path (lib/x86_64-linux-gnu), which the rest of the system doesn't search. Same reason
# the meson packages pass -Dlibdir=lib.
#
# DISABLE_EXTRA_LIBS: json-c falls back to libbsd's arc4random when the libc has none.
# Ours does have it, so the fallback never triggers — but the check runs against the
# builder image, and leaving it enabled is exactly how an optional Debian-only .so gets
# linked in and only shows up as a missing library in qemu.
#
# No static library, no test suite, and no apps: json_parse/json_pointer are debugging
# tools nothing in the image calls.
cmake -S . -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DBUILD_SHARED_LIBS=ON \
  -DBUILD_STATIC_LIBS=OFF \
  -DBUILD_APPS=OFF \
  -DBUILD_TESTING=OFF \
  -DDISABLE_EXTRA_LIBS=ON \
  -DDISABLE_WERROR=ON
cmake --build build -j"$(nproc)"
DESTDIR=/usr/local/rootfs cmake --install build
