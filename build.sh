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
# Packages compile against our own glibc, not the builder image's: sysroot/ is
# bind-mounted read-only and passed to gcc as --sysroot (see builder/build-package.sh).
# It holds glibc and nothing else of ours — ./build.sh glibc is what fills it, and
# SYSROOT_DIR points it elsewhere, which CI does. So glibc has to be built first:
#
#     ./build.sh glibc && ./build.sh coreutils
#
# Two trees, and the difference is the point. sysroot/ is what a build compiles *against*
# and holds exactly glibc; rootfs/ is what a build installs *into*, is cumulative, and is
# what an image is assembled from. See the SYSROOT_DIR note further down for what went
# wrong while they were the same directory.
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
FILLS_SYSROOT="${FILLS_SYSROOT:-}"

# The sysroot is a **glibc-only** tree, and it is a different directory from the
# cumulative rootfs/ staging tree. That distinction is the whole point, and it used to
# default the other way: with SYSROOT_DIR=rootfs, every package compiled against a tree
# holding every package built before it, so `--sysroot` handed configure the headers and
# libraries of our *other* packages and a build silently linked against whatever happened
# to be staged already.
#
# It is not hypothetical and the order it depends on is alphabetical. systemd installs
# libudev.h and libudev.so into the staging tree; util-linux is built after it, its
# configure found both through the sysroot, and lsblk and findmnt came out with
# libudev.so.1 in NEEDED. CI never saw it — the workflow has always passed
# SYSROOT_DIR=sysroot and staged a glibc-only tree there — so the divergence ran the
# wrong way round: a local build produced binaries CI would not, and the oci images,
# which omit systemd, could not be assembled locally at all.
#
# What the design says is "glibc comes from us, the rest is still Debian's" (see
# builder/build-package.sh). This is what makes that true off a CI runner too.
SYSROOT_DIR="${SYSROOT_DIR:-sysroot}"

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
    # Read-only: the sysroot is an input, and a separate tree from the DESTDIR mount
    # below, which stays writable.
    sysroot_abs=$(realpath "$SYSROOT_DIR")
    sysroot_mount=(--volume "$sysroot_abs":/usr/local/sysroot:ro,z
                   --env SYSROOT=/usr/local/sysroot)
fi

# Where this build installs. Normally the cumulative staging tree; for the one package
# that *fills* the sysroot, the sysroot — which is then mirrored into rootfs/ below, so
# that the staging tree an image is assembled from still has a glibc in it.
#
# FILLS_SYSROOT rather than a `[ "$PKG" = glibc ]` here, for the same reason NO_SYSROOT
# and LOCAL_SOURCE are flags in an env.sh: what is special about a package is a fact
# about that package, and this driver stays generic.
if [ -n "$FILLS_SYSROOT" ]; then
    destdir_tree="$SYSROOT_DIR"
else
    destdir_tree=rootfs
fi

mkdir -p rootfs output "$SYSROOT_DIR"

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
        [ -f "$ours" ] && sysroot_mount+=(--volume "$ours:$path:ro,z")
        # iconv() dlopens its character-set modules, and they are part of glibc too.
        if [ "$(basename "$path")" = "libc.so.6" ] && [ -d "$sysroot_abs/usr/lib/gconv" ]; then
            sysroot_mount+=(--volume "$sysroot_abs/usr/lib/gconv:$(dirname "$path")/gconv:ro,z")
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
    src_mount=(--volume "$PWD/$PKG_DIR/src":/usr/local/src:ro,z)
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
    src_mount=(--volume "$PWD/$PKG_DIR/$PACKAGE":/usr/local/src:z)
fi

# The pins, handed across the container boundary so the build can record what it is —
# builder/build-package.sh writes them into the staging tree as a component record, and
# image/build-rootfs.sh turns those into the SBOM. This is what "generate it, do not scan
# for it" means in practice (issue #75): every value here is already in env.sh, already
# verified by tools/fetch-sources.sh, and needs only writing down.
#
# It goes through --env rather than the host writing into rootfs/ afterwards because the
# staging tree belongs to the container: podman maps our uid to root inside it, and a
# directory the container created is not reliably ours to add a file to.
#
# FLFS_BUILDER is the toolchain's own content-hash reference. What compiled a binary is
# part of what it is — same package, same source, different compiler is a different
# artifact — and it is the one input to a build that env.sh has never described.
component_env=(
    --env "FLFS_PKG=$PKG"
    --env "FLFS_VERSION=$VERSION"
    --env "FLFS_LICENSE=${LICENSE:-NOASSERTION}"
    --env "FLFS_BUILDER=$BUILDER"
)
if [ -n "${LOCAL_SOURCE:-}" ]; then
    # No tarball and so no checksum: the source is this repository at whatever commit is
    # checked out, and `VERSION` is ours and means only what we say it means.
    component_env+=(--env "FLFS_ORIGIN=local")
else
    component_env+=(--env "FLFS_ORIGIN=tarball" --env "FLFS_URL=$URL" --env "FLFS_SHA256=$SHA256")
fi

# --network=none is the point of splitting prep out: the sources are on disk and the
# toolchain is in the image, so a compile that reaches for the internet is a bug, and
# this is what turns that from a claim into something it cannot do.
#
# Every bind mount carries `z`, which is podman asking SELinux to relabel the host path
# so a confined container may read it. Without it none of this works on a host running
# SELinux in enforcing mode — Fedora, RHEL and their derivatives — where the first thing
# a build does is fail with "install: cannot create directory
# '/usr/local/rootfs/usr': Permission denied", which names a permission the user plainly
# has and does not mention SELinux at all. It costs nothing on the Debian and Ubuntu
# hosts CI runs on: with no SELinux policy loaded, podman ignores the flag.
#
# `z` rather than `Z`: the shared label, because rootfs/ and the sysroot are read by more
# than one container — the package builds, and then the image assembly — and a private
# label would make each of those the only reader of a tree the next one has to open.
podman run --rm \
    --network=none \
    "${src_mount[@]}" \
    --volume "$PWD/$PKG_DIR/build.sh":/package-build.sh:ro,z \
    --volume "$PWD/$destdir_tree":/usr/local/rootfs:z \
    "${sysroot_mount[@]}" \
    "${component_env[@]}" \
    "$BUILDER" /build.sh

# The sysroot is also an ingredient of the image, so glibc has to end up in both trees.
# It is built into the sysroot rather than copied out of rootfs/ because that is the only
# way to get a tree that is *exactly* glibc: rootfs/ is cumulative, so a glibc rebuilt
# into a populated one could not be told apart from everything else in it afterwards.
#
# cp -a, so the loader, the merged-/usr symlinks and every mode survive. Not a fresh
# rootfs/ each time: this mirrors, the way a package build adds to the tree, because a
# glibc rebuild in the middle of a working tree should not throw the other packages away.
if [ -n "$FILLS_SYSROOT" ]; then
    echo ">> mirroring the sysroot into rootfs/"
    cp -a "$SYSROOT_DIR/." rootfs/
fi
