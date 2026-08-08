#!/bin/bash
# Build one package into the shared rootfs/ staging tree:
#
#     ./build.sh <package>        # e.g. ./build.sh coreutils
#
# Everything package-specific lives in the package's own directory under packages/:
#
#   packages/<pkg>/env.sh     version, tarball URL, its SHA256, and optionally
#                             NO_SYSROOT or LOCAL_SOURCE.
#   packages/<pkg>/build.sh   the configure/compile/install commands, sourced inside the
#                             container by builder/build-package.sh with the unpacked
#                             source tree as the working directory.
#
# A package no longer says anything about its build dependencies: there is one builder
# image for all of them, and builder/deps.txt is the whole list of what it contains. See
# docs/build-container.md.
#
# The tarball is fetched into downloads/ by tools/fetch-sources.sh, verified against that
# SHA256, and unpacked into the package's own directory. The compile then runs with
# --network=none: once prep is done, nothing about a build touches the network.
#
# Packages compile against our own glibc, not the builder image's: a tree that already
# has glibc staged in it is bind-mounted read-only and passed to gcc as --sysroot (see
# builder/build-package.sh). That tree defaults to rootfs/ — where ./build.sh glibc puts it
# — and can be pointed elsewhere with SYSROOT_DIR, which CI uses to keep each package's
# artifact free of glibc's files. So glibc has to be built before anything else:
#
#     ./build.sh glibc && ./build.sh coreutils
set -euo pipefail

PKG="${1:-}"

if [ -z "$PKG" ]; then
    echo "usage: $0 <package>" >&2
    echo "packages: $(for e in packages/*/env.sh; do basename "$(dirname "$e")"; done | tr '\n' ' ')" >&2
    exit 1
fi

# Accept both `coreutils` and the path a shell tab-completes to, `packages/coreutils/`.
PKG="${PKG%/}"
PKG="${PKG#packages/}"
PKG_DIR="packages/$PKG"

if [ ! -f "$PKG_DIR/env.sh" ]; then
    echo "error: unknown package '$PKG' (no $PKG_DIR/env.sh)" >&2
    exit 1
fi

# env.sh may refer to $PKG when composing its download URL.
source "$PKG_DIR/env.sh"

NO_SYSROOT="${NO_SYSROOT:-}"
SYSROOT_DIR="${SYSROOT_DIR:-rootfs}"

# glibc itself is what fills the sysroot, and the kernel is freestanding — neither has
# one to build against.
sysroot_mount=()
if [ -z "$NO_SYSROOT" ]; then
    if [ ! -e "$SYSROOT_DIR/usr/lib/libc.so.6" ]; then
        echo "error: no glibc in the sysroot ($SYSROOT_DIR/usr/lib/libc.so.6 is missing)" >&2
        echo "       packages are compiled against our own glibc, so build it first:" >&2
        echo "           ./build.sh glibc" >&2
        echo "       (or set NO_SYSROOT=1 to compile against the builder image's glibc)" >&2
        exit 1
    fi
    # Read-only: the sysroot is an input. It is usually the same tree as the DESTDIR
    # mount below, which stays writable.
    sysroot_abs=$(realpath "$SYSROOT_DIR")
    sysroot_mount=(--volume "$sysroot_abs":/usr/local/sysroot:ro
                   --env SYSROOT=/usr/local/sysroot)
fi

mkdir -p rootfs output

# Pull or build the one image everything compiles in, and fetch the sources — the only
# two steps here that need the network. Its output is two lines and it is the only place
# a build can spend minutes on something other than compiling, so let it through: a run
# that silently rebuilt an image instead of pulling it should say so.
./tools/prep.sh
BUILDER=$(./tools/image-tags.sh builder)

# The builder also has to *run* what it compiles: help2man asks a freshly built ptx for
# its --help, ncurses runs its own tic. Those binaries are linked against our glibc, and
# sid's loader is older than that — ptx calls memset_explicit, new in 2.43, so it dies
# with "version `GLIBC_2.43' not found" and the build stops. So the container gets our
# glibc as its own libc, not just as a sysroot to compile against: each file the image's
# libc6 owns is bind-mounted over with ours. glibc stays backwards compatible, so the
# Debian binaries in there (gcc, make, perl) keep working on it.
#
# Bind mounts rather than swapping the files from inside the container: they are all in
# place before the first process starts, so nothing ever runs against a half-swapped
# glibc — replacing the loader and libc.so.6 one at a time would kill the very shell
# doing the replacing.
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

# A package's source is normally a pinned upstream tarball, but it does not have to be:
# LOCAL_SOURCE=1 in env.sh means the source is in this repository, under
# packages/<pkg>/src, with nothing to download and nothing to unpack.
#
# That tree is mounted read-only, unlike the extracted tarball every other package gets.
# It is tracked by git, so a build that dropped object files into it would turn a
# successful build into a dirty working tree — the package's build.sh compiles straight
# to DESTDIR instead. See CLAUDE.md.
if [ -n "${LOCAL_SOURCE:-}" ]; then
    if [ ! -d "$PKG_DIR/src" ]; then
        echo "error: $PKG sets LOCAL_SOURCE but has no $PKG_DIR/src directory" >&2
        exit 1
    fi
    src_mount=(--volume "$PWD/$PKG_DIR/src":/usr/local/src:ro)
else
    # Tarballs are shared across packages' rebuilds and never belong to any one of them,
    # so they live in one gitignored directory rather than next to whichever package
    # downloaded them first. prep.sh above already fetched every package's; this
    # re-checks just ours, so a tarball deleted or corrupted since then is caught here
    # rather than half-extracted.
    ./tools/fetch-sources.sh "$PKG"

    # Into a directory this script names, rather than whichever one the tarball happens
    # to contain: $PACKAGE is derived from $VERSION, so the unpacked tree is versioned
    # even when upstream's is not. Debian's ca-certificates unpacks to a bare
    # `ca-certificates/`, and with that as $PACKAGE a version bump would find the
    # previous snapshot already sitting there, skip the extraction and build the old
    # certificates under the new version number. --strip-components=1 is a no-op for
    # every other package here: each of their tarballs has exactly one top-level
    # directory, named $PACKAGE already.
    if [ ! -d "$PKG_DIR/$PACKAGE" ]; then
        echo "Extracting ${TARBALL}..."
        # Assembled under another name and moved into place, so that an interrupted
        # extraction leaves nothing for the next run to mistake for a finished one.
        staging="$PKG_DIR/.extracting"
        rm -rf "$staging"
        mkdir -p "$staging"
        tar -xf "downloads/$TARBALL" -C "$staging" --strip-components=1
        mv "$staging" "$PKG_DIR/$PACKAGE"
    else
        echo "Directory $PKG_DIR/$PACKAGE already exists, skipping extraction."
    fi
    src_mount=(--volume "$PWD/$PKG_DIR/$PACKAGE":/usr/local/src)
fi

# --network=none is the point of splitting prep out: the sources are on disk and the
# toolchain is in the image, so a compile that reaches for the internet is a bug, and
# this is what turns that from a claim into something it cannot do.
podman run --rm \
    --network=none \
    "${src_mount[@]}" \
    --volume "$PWD/$PKG_DIR/build.sh":/package-build.sh:ro \
    --volume "$PWD/rootfs":/usr/local/rootfs \
    "${sysroot_mount[@]}" \
    "$BUILDER" /build.sh
