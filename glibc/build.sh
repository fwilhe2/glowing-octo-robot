#!/bin/bash

# mkdir build
# pushd build
# ../configure --prefix=/usr/local/rootfs
# make
# make install
# popd


# fixme
wget http://ftp.de.debian.org/debian/pool/main/g/glibc/libc-bin_2.42-6_amd64.deb
ar x libc-bin_2.42-6_amd64.deb
tar xf data.tar.xz -C /usr/local/rootfs
