#!/bin/bash
set -euo pipefail

set -x


mkdir build
pushd build
../configure --prefix=/usr/local/rootfs
make
make install
popd