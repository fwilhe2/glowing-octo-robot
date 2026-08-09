# util-linux's login hard-requires PAM, so we ship it rather than strip it.
# Disable the features that would pull in libs we don't build (libaudit, libselinux,
# libeconf, NIS) and the docs toolchain.
# -Dlibdir=lib: meson otherwise defaults to the Debian multiarch path, which would put
# libpam.so.0 and the PAM modules where login can't find them.
# --buildtype=release: meson's default is `debug`, which is -O0. See "the three things
# that break silently" in CLAUDE.md.
meson setup --prefix /usr --buildtype=release -Dlibdir=lib \
  -Ddocs=disabled -Daudit=disabled -Dselinux=disabled \
  -Deconf=disabled -Dnis=disabled -Dexamples=false \
  build
meson compile -C build
meson install -C build --destdir /usr/local/rootfs
