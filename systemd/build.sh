#!/bin/bash
set -euo pipefail

# merged-/usr staging: /bin /sbin /lib /lib64 become symlinks into /usr
install -d /usr/local/rootfs/usr/{bin,sbin,lib}
ln -sfn usr/bin  /usr/local/rootfs/bin
ln -sfn usr/sbin /usr/local/rootfs/sbin
ln -sfn usr/lib  /usr/local/rootfs/lib
ln -sfn usr/lib  /usr/local/rootfs/lib64

# -Dc_args=-Wno-error: systemd builds -Werror=override-init etc. that trip on this
# bleeding-edge sid toolchain (e.g. errno aliases in errno-to-name.inc).
meson setup --prefix /usr -Dc_args=-Wno-error build
pushd build
meson compile
meson install --destdir /usr/local/rootfs

popd