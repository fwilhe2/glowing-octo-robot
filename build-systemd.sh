#!/bin/bash

./build.sh

podman build -t localhost/systemd-lfs-builder systemd

VERSION="258.1"
VVERSION="v$VERSION"
PACKAGE="systemd-${VERSION}"
TARBALL="$VVERSION.tar.gz"
URL="https://github.com/systemd/systemd/archive/refs/tags/${TARBALL}"
DIR="systemd"

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

podman run --volume "$PWD/$DIR/$VERSION":/usr/local/src --volume "$PWD"/rootfs:/usr/local/rootfs localhost/systemd-lfs-builder /build.sh
