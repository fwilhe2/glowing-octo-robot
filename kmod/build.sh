#!/bin/bash
set -euo pipefail

# merged-/usr staging: /bin /sbin /lib /lib64 become symlinks into /usr
install -d /usr/local/rootfs/usr/{bin,sbin,lib}
ln -sfn usr/bin  /usr/local/rootfs/bin
ln -sfn usr/sbin /usr/local/rootfs/sbin
ln -sfn usr/lib  /usr/local/rootfs/lib
ln -sfn usr/lib  /usr/local/rootfs/lib64

# -Dlibdir=lib: meson otherwise defaults to the Debian multiarch path.
meson setup --prefix /usr -Dlibdir=lib builddir/
meson compile -C builddir/
meson install -C builddir/ --destdir /usr/local/rootfs
