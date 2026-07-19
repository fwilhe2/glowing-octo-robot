#!/bin/bash
set -euo pipefail

set -x


export CC="gcc -nostdinc -I/usr/local/libs/include"
export LD_LIBRARY_PATH="/usr/local/libs/lib"
export LDFLAGS="-L/usr/local/libs/lib"
export CFLAGS="-I/usr/local/libs/include"

# merged-/usr staging: /bin /sbin /lib /lib64 become symlinks into /usr
install -d /usr/local/rootfs/usr/{bin,sbin,lib}
ln -sfn usr/bin  /usr/local/rootfs/bin
ln -sfn usr/sbin /usr/local/rootfs/sbin
ln -sfn usr/lib  /usr/local/rootfs/lib
ln -sfn usr/lib  /usr/local/rootfs/lib64

./configure --disable-asciidoc --prefix=/usr
make
make install DESTDIR=/usr/local/rootfs