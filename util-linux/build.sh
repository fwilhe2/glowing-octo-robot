#!/bin/bash

./configure --disable-asciidoc --prefix=/usr/local/rootfs
make
make install