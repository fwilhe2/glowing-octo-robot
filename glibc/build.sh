#!/bin/bash
set -euo pipefail

# merged-/usr staging: /bin /sbin /lib /lib64 become symlinks into /usr
install -d /usr/local/rootfs/usr/{bin,sbin,lib}
ln -sfn usr/bin  /usr/local/rootfs/bin
ln -sfn usr/sbin /usr/local/rootfs/sbin
ln -sfn usr/lib  /usr/local/rootfs/lib
ln -sfn usr/lib  /usr/local/rootfs/lib64

mkdir build
pushd build
# --disable-werror: sid's linux-libc-dev redefines OPEN_TREE_CLONE etc. that glibc's
# own sys/mount.h also defines, which -Werror turns into a fatal build error.
../configure --prefix=/usr --disable-werror
make
make install DESTDIR=/usr/local/rootfs
popd