#!/bin/bash

mkdir build
meson setup builddir/
meson compile -C builddir/
meson install -C builddir/ --destdir /usr/local/rootfs/
