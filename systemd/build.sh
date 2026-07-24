# -Dc_args=-Wno-error=override-init: systemd promotes -Werror=override-init specifically,
# which a blanket -Wno-error does NOT cancel; the errno aliases in the generated
# errno-to-name.inc trip it on this bleeding-edge sid toolchain.
# The disabled features drop optional runtime libs we don't ship (libselinux, libseccomp,
# libaudit, libpam, libcrypto); libcap and libcrypt(libxcrypt) are built as packages.
# -Dlibdir=lib: meson defaults libdir to the Debian multiarch path
# (lib/x86_64-linux-gnu) on this builder, which the rest of the system doesn't search.
meson setup --prefix /usr -Dlibdir=lib -Dc_args=-Wno-error=override-init \
  -Dselinux=disabled -Dseccomp=disabled -Daudit=disabled \
  -Dpam=disabled -Dopenssl=disabled -Dlibcryptsetup=disabled \
  build
meson compile -C build
meson install -C build --destdir /usr/local/rootfs
