#!/bin/bash

source xz/env.sh

./build.sh

podman build -t localhost/xz-lfs-builder xz


if [ ! -f "${TARBALL}" ]; then
    echo "Downloading ${TARBALL}..."
    wget -q "${URL}"
else
    echo "${TARBALL} already exists, skipping download."
fi

mkdir -p "${DIR}"

if [ ! -d "${DIR}/$PACKAGE" ]; then
    echo "Extracting ${TARBALL}..."
    tar -xf "${TARBALL}" -C "${DIR}"
else
    echo "Directory ${DIR}/$PACKAGE already exists, skipping extraction."
fi

podman run --volume "$PWD/$DIR/$PACKAGE":/usr/local/src --volume "$PWD"/rootfs:/usr/local/rootfs localhost/xz-lfs-builder /build.sh
