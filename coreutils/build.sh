#!/bin/bash

export FORCE_UNSAFE_CONFIGURE=1

./configure --prefix=/usr/local/rootfs
make
make install