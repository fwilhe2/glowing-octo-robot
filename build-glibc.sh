#!/bin/bash

./build.sh

podman build -t localhost/glibc-lfs-builder glibc

VERSION="2.42"
TARBALL="glibc-${VERSION}.tar.gz"
URL="https://ftp.fau.de/gnu/glibc/${TARBALL}"
DIR="glibc"

if [ ! -f "${TARBALL}" ]; then
    echo "Downloading ${TARBALL}..."
    wget -q "${URL}"
else
    echo "${TARBALL} already exists, skipping download."
fi

mkdir -p "${DIR}"

if [ ! -d "${DIR}/glibc-${VERSION}" ]; then
    echo "Extracting ${TARBALL}..."
    tar -xf "${TARBALL}" -C "${DIR}"
else
    echo "Directory ${DIR}/glibc-${VERSION} already exists, skipping extraction."
fi

podman run --volume "$PWD"/glibc/glibc-${VERSION}:/usr/local/src --volume "$PWD"/rootfs:/usr/local/rootfs localhost/glibc-lfs-builder /build.sh
