# -Dc_args=-Wno-error=override-init: systemd promotes -Werror=override-init specifically,
# which a blanket -Wno-error does NOT cancel; the errno aliases in the generated
# errno-to-name.inc trip it on this bleeding-edge sid toolchain.
# The disabled features drop optional runtime libs we don't ship (libselinux, libseccomp,
# libaudit, libcrypto); libcap, libpam and libcrypt(libxcrypt) are built as packages.
#
# -Dpam=enabled builds pam_systemd, which is what registers a login as a session with
# systemd-logind — without it logind runs but never sees a seat used, so `loginctl
# list-sessions` stays empty. It is referenced from _files/etc/pam.d/login.
# -Dlibdir=lib: meson defaults libdir to the Debian multiarch path
# (lib/x86_64-linux-gnu) on this builder, which the rest of the system doesn't search.
#
# -Dc_args replaces the CFLAGS environment variable rather than adding to it, so the
# sysroot flags lib/build-package.sh exports have to be carried over by hand or systemd
# would be the one package still compiled against the builder's glibc.
meson setup --prefix /usr -Dlibdir=lib -Dc_args="${CFLAGS:-} -Wno-error=override-init" \
  -Dselinux=disabled -Dseccomp=disabled -Daudit=disabled \
  -Dpam=enabled -Dopenssl=disabled -Dlibcryptsetup=disabled \
  build
meson compile -C build
meson install -C build --destdir /usr/local/rootfs
