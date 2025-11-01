#!/bin/bash

source kmod/env.sh

./build.sh

podman build -t localhost/kmod-lfs-builder kmod

if [ ! -f "${TARBALL}" ]; then
    echo "Downloading ${TARBALL}..."
    wget -q "${URL}"
else
    echo "${TARBALL} already exists, skipping download."
fi

mkdir -p "${DIR}"

if [ ! -d "${DIR}/${DIR}-${VERSION}" ]; then
    echo "Extracting ${TARBALL}..."
    tar -xf "${TARBALL}" -C "${DIR}"
else
    echo "Directory ${DIR}/${DIR}-${VERSION} already exists, skipping extraction."
fi

podman run --volume "$PWD/$DIR/${DIR}-${VERSION}":/usr/local/src --volume "$PWD"/rootfs:/usr/local/rootfs localhost/kmod-lfs-builder /build.sh
