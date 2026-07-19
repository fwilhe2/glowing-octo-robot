#!/bin/bash
set -euo pipefail

# merged-/usr staging: /bin /sbin /lib /lib64 become symlinks into /usr
install -d /usr/local/rootfs/usr/{bin,sbin,lib}
ln -sfn usr/bin  /usr/local/rootfs/bin
ln -sfn usr/sbin /usr/local/rootfs/sbin
ln -sfn usr/lib  /usr/local/rootfs/lib
ln -sfn usr/lib  /usr/local/rootfs/lib64

# util-linux's login hard-requires PAM, so we ship it rather than strip it.
# Disable the features that would pull in libs we don't build (libaudit, libselinux,
# libeconf, NIS) and the docs toolchain.
meson setup --prefix /usr \
  -Ddocs=disabled -Daudit=disabled -Dselinux=disabled \
  -Deconf=disabled -Dnis=disabled -Dexamples=false \
  build
meson compile -C build
meson install -C build --destdir /usr/local/rootfs
