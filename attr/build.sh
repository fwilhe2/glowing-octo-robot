#!/bin/bash

./autogen.sh
./configure --prefix=/usr/local/rootfs
make
make install