#!/bin/bash

./build.sh

podman build -t localhost/bash-lfs-builder bash

BASH_VERSION="5.3"
BASH_TARBALL="bash-${BASH_VERSION}.tar.gz"
BASH_URL="https://ftp.fau.de/gnu/bash/${BASH_TARBALL}"
BASH_DIR="bash"

if [ ! -f "${BASH_TARBALL}" ]; then
    echo "Downloading ${BASH_TARBALL}..."
    wget -q "${BASH_URL}"
else
    echo "${BASH_TARBALL} already exists, skipping download."
fi

mkdir -p "${BASH_DIR}"

if [ ! -d "${BASH_DIR}/bash-${BASH_VERSION}" ]; then
    echo "Extracting ${BASH_TARBALL}..."
    tar -xf "${BASH_TARBALL}" -C "${BASH_DIR}"
else
    echo "Directory ${BASH_DIR}/bash-${BASH_VERSION} already exists, skipping extraction."
fi

podman run --volume "$PWD"/bash/bash-5.3:/usr/local/src --volume "$PWD"/rootfs:/usr/local/rootfs localhost/bash-lfs-builder /build.sh
