#!/bin/bash
set -euo pipefail

set -x


export CC="gcc -nostdinc -I/usr/local/libs/include"
export LD_LIBRARY_PATH="/usr/local/libs/lib"
export LDFLAGS="-L/usr/local/libs/lib"
export CFLAGS="-I/usr/local/libs/include"

mkdir build
meson setup builddir/
meson compile -C builddir/
meson install -C builddir/ --destdir /usr/local/rootfs/
