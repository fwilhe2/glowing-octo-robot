#!/bin/bash

mkdir build
pushd build
../configure --prefix=/usr/local/rootfs
make
make install
popd