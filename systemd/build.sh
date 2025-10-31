#!/bin/bash

mkdir {build,testdir}
meson setup build
pushd build
meson compile
meson install --destdir /usr/local/rootfs/

popd