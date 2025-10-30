#!/bin/bash

mkdir build
pushd build
../configure --prefix=/usr/local/rootfs
popd
make
make install DESTDIR=/usr/local/rootfs