#!/bin/bash
set -euo pipefail

# merged-/usr staging: /bin /sbin /lib /lib64 become symlinks into /usr
install -d /usr/local/rootfs/usr/{bin,sbin,lib}
ln -sfn usr/bin  /usr/local/rootfs/bin
ln -sfn usr/sbin /usr/local/rootfs/sbin
ln -sfn usr/lib  /usr/local/rootfs/lib
ln -sfn usr/lib  /usr/local/rootfs/lib64

# systemd promotes -Werror=override-init specifically, which a blanket -Wno-error does
# NOT cancel; the errno aliases in the generated errno-to-name.inc trip it on this
# bleeding-edge sid toolchain. Negate that specific warning.
meson setup --prefix /usr -Dc_args=-Wno-error=override-init build
pushd build
meson compile
meson install --destdir /usr/local/rootfs

popd