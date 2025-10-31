#!/bin/bash

mkdir {build,testdir}
pushd build
meson setup build
meson compile
meson install --destdir /usr/local/rootfs/

popd