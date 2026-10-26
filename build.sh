#!/bin/bash
# Build one package into its own staging tree, and merge them all into rootfs/:
#
#     ./build.sh <package>        # e.g. ./build.sh coreutils
#
# A package is two files:
#
#   packages/<pkg>/env.sh     VERSION, TARBALL, URL, SHA256, LICENSE, and optionally
#                             NO_SYSROOT, LOCAL_SOURCE, EXTENSION, VENDOR_*, FOLLOWS.
#   packages/<pkg>/build.sh   configure/compile/install, sourced by
#                             builder/build-package.sh in the unpacked source tree.
#
# The compile runs --network=none against our glibc (staging/glibc/rootfs, or
# SYSROOT_DIR), so glibc is built first. It installs into staging/<pkg>/, which replaces
# the previous build only once it succeeded, and rootfs/ is then re-merged from every
# package's tree. With EXTENSION=<name> the files go to a system extension instead.
set -euo pipefail

source tools/lib.sh

if [ -z "${1:-}" ]; then
    echo "usage: $0 <package>" >&2
    echo "packages: $(all_packages | tr '\n' ' ')" >&2
    exit 1
fi

PKG=$(package_name "$1")
PKG_DIR="packages/$PKG"
load_env "$PKG"

NO_SYSROOT="${NO_SYSROOT:-}"
SYSROOT_DIR="${SYSROOT_DIR:-staging/glibc/rootfs}"

# Built into a scratch tree, moved into place on success. Files in it belong to the
# container's users, hence the podman unshare fallback.
STAGE="staging/$PKG"
BUILDING="staging/.building-$PKG"
as_owner() { "$@" 2>/dev/null || podman unshare "$@"; }
as_owner rm -rf "$BUILDING"
DEST_DIR="$BUILDING/rootfs"
[ -z "${EXTENSION:-}" ] || DEST_DIR="$BUILDING/extensions/$EXTENSION"
mkdir -p "$DEST_DIR"

sysroot_mount=()
if [ -z "$NO_SYSROOT" ]; then
    if [ ! -e "$SYSROOT_DIR/usr/lib/libc.so.6" ]; then
        echo "error: no glibc in the sysroot ($SYSROOT_DIR/usr/lib/libc.so.6 is missing)" >&2
        echo "       packages are compiled against our own glibc, so build it first:" >&2
        echo "           ./build.sh glibc" >&2
        echo "       (a checkout from before staging/ existed has glibc in rootfs/ only, and" >&2
        echo "       needs this once; or set NO_SYSROOT=1 to compile against the builder" >&2
        echo "       image's glibc)" >&2
        exit 1
    fi
    sysroot_abs=$(realpath "$SYSROOT_DIR")
    sysroot_mount=(--volume "$sysroot_abs":/usr/local/sysroot:ro
                   --env SYSROOT=/usr/local/sysroot)
fi

mkdir -p output

# The only network step: pull or build the builder image, fetch the sources.
./tools/prep.sh
BUILDER=$(./tools/image-tags.sh builder)

# Builds run what they just compiled (help2man runs ptx, ncurses its own tic), linked
# against our glibc, which can be newer than sid's. So the container runs on ours: every
# file the image's libc6 owns is bind-mounted over, before the first process starts.
if [ -z "$NO_SYSROOT" ]; then
    while read -r path; do
        ours="$sysroot_abs/usr/lib/$(basename "$path")"
        [ -f "$ours" ] && sysroot_mount+=(--volume "$ours:$path:ro")
        # iconv() dlopens its character-set modules, and they are part of glibc too.
        if [ "$(basename "$path")" = "libc.so.6" ] && [ -d "$sysroot_abs/usr/lib/gconv" ]; then
            sysroot_mount+=(--volume "$sysroot_abs/usr/lib/gconv:$(dirname "$path")/gconv:ro")
        fi
    done < <(podman run --rm "$BUILDER" \
        sh -c 'dpkg -L libc6 | while read -r p; do [ -f "$p" ] && printf "%s\n" "$p"; done')
fi

# LOCAL_SOURCE=1: the source is packages/<pkg>/src, mounted read-only so a build cannot
# dirty the checkout.
if [ -n "${LOCAL_SOURCE:-}" ]; then
    if [ ! -d "$PKG_DIR/src" ]; then
        echo "error: $PKG sets LOCAL_SOURCE but has no $PKG_DIR/src directory" >&2
        exit 1
    fi
    src_mount=(--volume "$PWD/$PKG_DIR/src":/usr/local/src:ro)
else
    # Re-verified, so a tarball corrupted since prep is caught before extraction.
    ./tools/fetch-sources.sh "$PKG"

    # Into packages/<pkg>/$PACKAGE whatever the tarball's top directory is called, so the
    # tree is versioned even when upstream's is not (ca-certificates).
    if [ ! -d "$PKG_DIR/$PACKAGE" ]; then
        echo "Extracting ${TARBALL}..."
        # Moved into place when complete, so an interrupted extraction is not reused.
        staging="$PKG_DIR/.extracting"
        rm -rf "$staging"
        mkdir -p "$staging"
        tar -xf "downloads/$TARBALL" -C "$staging" --strip-components=1
        # The vendored dependencies (./vendor/...) go in on top.
        if [ -n "${VENDOR_TARBALL:-}" ]; then
            tar -xf "downloads/$VENDOR_TARBALL" -C "$staging"
        fi
        mv "$staging" "$PKG_DIR/$PACKAGE"
    else
        echo "Directory $PKG_DIR/$PACKAGE already exists, skipping extraction."
    fi
    src_mount=(--volume "$PWD/$PKG_DIR/$PACKAGE":/usr/local/src)
fi

# The pins, for the component record builder/build-package.sh writes and the SBOM is
# made from. FLFS_BUILDER is the one build input env.sh does not describe.
component_env=(
    --env "FLFS_PKG=$PKG"
    --env "FLFS_VERSION=$VERSION"
    --env "FLFS_LICENSE=${LICENSE:-NOASSERTION}"
    --env "FLFS_BUILDER=$BUILDER"
    --env "SOURCE_DATE_EPOCH=$FLFS_SOURCE_DATE_EPOCH"
)
if [ -n "${LOCAL_SOURCE:-}" ]; then
    component_env+=(--env "FLFS_ORIGIN=local")
else
    component_env+=(--env "FLFS_ORIGIN=tarball" --env "FLFS_URL=$URL" --env "FLFS_SHA256=$SHA256")
    if [ -n "${VENDOR_TARBALL:-}" ]; then
        component_env+=(--env "FLFS_VENDOR_URL=$VENDOR_URL" --env "FLFS_VENDOR_SHA256=$VENDOR_SHA256")
    fi
fi

# label=disable for SELinux hosts: relabelling with :z would rewrite the checkout's labels.
podman run --rm \
    --network=none \
    --security-opt label=disable \
    "${src_mount[@]}" \
    --volume "$PWD/$PKG_DIR/build.sh":/package-build.sh:ro \
    --volume "$PWD/$DEST_DIR":/usr/local/rootfs \
    "${sysroot_mount[@]}" \
    "${component_env[@]}" \
    "$BUILDER" /build.sh

as_owner rm -rf "$STAGE"
mv "$BUILDING" "$STAGE"
./tools/merge-staging.sh
