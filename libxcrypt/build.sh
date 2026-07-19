#!/bin/bash
set -euo pipefail

# merged-/usr staging: /bin /sbin /lib /lib64 become symlinks into /usr
install -d /usr/local/rootfs/usr/{bin,sbin,lib}
ln -sfn usr/bin  /usr/local/rootfs/bin
ln -sfn usr/sbin /usr/local/rootfs/sbin
ln -sfn usr/lib  /usr/local/rootfs/lib
ln -sfn usr/lib  /usr/local/rootfs/lib64

# --enable-obsolete-api=glibc builds libcrypt.so.1 with the glibc-compatible ABI that
# systemd (linked against Debian's libcrypt) expects. glibc 2.42 no longer ships it.
./configure --prefix=/usr --enable-obsolete-api=glibc --disable-failure-tokens
make
make install DESTDIR=/usr/local/rootfs
