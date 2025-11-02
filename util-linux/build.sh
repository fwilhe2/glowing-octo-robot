#!/bin/bash

export CC="gcc -nostdinc -I/usr/local/libs/include"
export LD_LIBRARY_PATH="/usr/local/libs/lib"
export LDFLAGS="-L/usr/local/libs/lib"
export CFLAGS="-I/usr/local/libs/include"

./configure --disable-asciidoc --prefix=/usr/local/rootfs
make
make install