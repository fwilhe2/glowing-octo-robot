#!/bin/bash
set -euo pipefail

# merged-/usr staging: /bin /sbin /lib /lib64 become symlinks into /usr
install -d /usr/local/rootfs/usr/{bin,sbin,lib}
ln -sfn usr/bin  /usr/local/rootfs/bin
ln -sfn usr/sbin /usr/local/rootfs/sbin
ln -sfn usr/lib  /usr/local/rootfs/lib
ln -sfn usr/lib  /usr/local/rootfs/lib64

# -Dc_args=-Wno-error=override-init: systemd promotes -Werror=override-init specifically,
# which a blanket -Wno-error does NOT cancel; the errno aliases in the generated
# errno-to-name.inc trip it on this bleeding-edge sid toolchain.
# The disabled features drop optional runtime libs we don't ship (libselinux, libseccomp,
# libaudit, libpam, libcrypto); libcap and libcrypt(libxcrypt) are built as packages.
meson setup --prefix /usr -Dc_args=-Wno-error=override-init \
  -Dselinux=disabled -Dseccomp=disabled -Daudit=disabled \
  -Dpam=disabled -Dopenssl=disabled -Dlibcryptsetup=disabled \
  build
pushd build
meson compile
meson install --destdir /usr/local/rootfs

popd