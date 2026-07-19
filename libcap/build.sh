#!/bin/bash
set -euo pipefail

# merged-/usr staging: /bin /sbin /lib /lib64 become symlinks into /usr
install -d /usr/local/rootfs/usr/{bin,sbin,lib}
ln -sfn usr/bin  /usr/local/rootfs/bin
ln -sfn usr/sbin /usr/local/rootfs/sbin
ln -sfn usr/lib  /usr/local/rootfs/lib
ln -sfn usr/lib  /usr/local/rootfs/lib64

# libcap uses a plain Makefile. lib=lib keeps it out of /usr/lib64; PAM_CAP=no avoids
# pulling in a PAM dependency we don't ship.
make prefix=/usr lib=lib GOLANG=no
make install prefix=/usr lib=lib GOLANG=no PAM_CAP=no DESTDIR=/usr/local/rootfs
