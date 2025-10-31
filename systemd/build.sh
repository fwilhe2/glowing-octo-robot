#!/bin/bash

mkdir {build,testdir}
meson build
make install DESTDIR=/usr/local/rootfs