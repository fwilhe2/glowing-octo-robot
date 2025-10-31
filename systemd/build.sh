#!/bin/bash

mkdir {build,testdir}
meson build
make
make install DESTDIR=/usr/local/rootfs