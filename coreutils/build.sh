#!/bin/bash
set -euo pipefail

set -x


export CC="gcc -I/usr/local/libs/include"
export LD_LIBRARY_PATH="/usr/local/libs/lib"
export LDFLAGS="-L/usr/local/libs/lib"
export CFLAGS="-I/usr/local/libs/include"

export FORCE_UNSAFE_CONFIGURE=1

./configure --prefix=/usr/local/rootfs
make
make install