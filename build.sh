#!/bin/bash

podman build -t localhost/abstract-lfs-builder .

mkdir -p {rootfs,output}
