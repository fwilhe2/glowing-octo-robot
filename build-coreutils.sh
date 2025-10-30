#!/bin/bash

./build.sh

podman build -t localhost/coreutils-lfs-builder coreutils

VERSION="9.8"
TARBALL="coreutils-${VERSION}.tar.gz"
URL="https://ftp.fau.de/gnu/coreutils/${TARBALL}"
DIR="coreutils"

if [ ! -f "${TARBALL}" ]; then
    echo "Downloading ${TARBALL}..."
    wget -q "${URL}"
else
    echo "${TARBALL} already exists, skipping download."
fi

mkdir -p "${DIR}"

if [ ! -d "${DIR}/coreutils-${VERSION}" ]; then
    echo "Extracting ${TARBALL}..."
    tar -xf "${TARBALL}" -C "${DIR}"
else
    echo "Directory ${DIR}/coreutils-${VERSION} already exists, skipping extraction."
fi

podman run --volume "$PWD"/coreutils/coreutils-${VERSION}:/usr/local/src --volume "$PWD"/rootfs:/usr/local/rootfs localhost/coreutils-lfs-builder /build.sh
