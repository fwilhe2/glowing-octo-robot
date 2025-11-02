#!/bin/bash

source e2fsprogs/env.sh

./build.sh

podman build -t localhost/e2fsprogs-lfs-builder e2fsprogs


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

podman run --volume "$PWD/$DIR/$PACKAGE":/usr/local/src --volume "$PWD"/libs:/usr/local/libs --volume "$PWD"/rootfs:/usr/local/rootfs localhost/e2fsprogs-lfs-builder /build.sh
