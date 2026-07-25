#!/bin/bash
# Build one package into the shared rootfs/ staging tree:
#
#     ./build.sh <package>        # e.g. ./build.sh coreutils
#
# Everything package-specific lives in the package's own directory:
#
#   <package>/env.sh     version, tarball URL, and optionally BUILD_DEP (the Debian
#                        source package to take build-dependencies from, defaults to
#                        the package directory name) and EXTRA_DEPS (extra apt
#                        packages build-dep doesn't cover).
#   <package>/build.sh   the configure/compile/install commands, sourced inside the
#                        container by lib/build-package.sh with the unpacked source
#                        tree as the working directory.
set -euo pipefail

PKG="${1:-}"

if [ -z "$PKG" ]; then
    echo "usage: $0 <package>" >&2
    echo "packages: $(for e in */env.sh; do dirname "$e"; done | tr '\n' ' ')" >&2
    exit 1
fi

PKG="${PKG%/}"

if [ ! -f "$PKG/env.sh" ]; then
    echo "error: unknown package '$PKG' (no $PKG/env.sh)" >&2
    exit 1
fi

# env.sh may refer to $PKG when composing its download URL.
source "$PKG/env.sh"

BUILD_DEP="${BUILD_DEP:-$PKG}"
EXTRA_DEPS="${EXTRA_DEPS:-}"

./build-base.sh

podman build -t "localhost/$PKG-lfs-builder" \
    --build-arg "BUILD_DEP=$BUILD_DEP" \
    --build-arg "EXTRA_DEPS=$EXTRA_DEPS" \
    -f package.Containerfile .

if [ ! -f "$TARBALL" ]; then
    echo "Downloading ${TARBALL}..."
    wget -q "$URL"
else
    echo "${TARBALL} already exists, skipping download."
fi

if [ ! -d "$PKG/$PACKAGE" ]; then
    echo "Extracting ${TARBALL}..."
    tar -xf "$TARBALL" -C "$PKG"
else
    echo "Directory $PKG/$PACKAGE already exists, skipping extraction."
fi

podman run --rm \
    --volume "$PWD/$PKG/$PACKAGE":/usr/local/src \
    --volume "$PWD/$PKG/build.sh":/package-build.sh:ro \
    --volume "$PWD/rootfs":/usr/local/rootfs \
    "localhost/$PKG-lfs-builder" /build.sh
