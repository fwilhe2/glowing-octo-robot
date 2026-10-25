#!/bin/bash
# Build one package into its own staging tree, and merge them all into rootfs/:
#
#     ./build.sh <package>        # e.g. ./build.sh coreutils
#
# Everything package-specific lives in the package's own directory under packages/:
#
#   packages/<pkg>/env.sh     version, tarball URL, its SHA256, and optionally
#                             NO_SYSROOT, LOCAL_SOURCE or EXTENSION.
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
# builder/build-package.sh). That tree is glibc's own staging tree, staging/glibc/rootfs,
# which holds glibc and nothing else — the same thing CI unpacks the glibc artifact into
# as sysroot/, and SYSROOT_DIR points it there. It used to be rootfs/ itself, which made
# a local build compile against our headers for whatever happened to be staged already,
# where CI's compiled against Debian's. So glibc has to be built before anything else:
#
#     ./build.sh glibc && ./build.sh coreutils
#
# The install target is staging/<pkg>/rootfs, a tree of this package's files alone, and
# tools/merge-staging.sh then rebuilds rootfs/ from every package's — so rootfs/ is
# derived, never installed into, and a rebuilt package replaces its files rather than
# adding to whatever an older build left behind. The layout is the package's CI artifact,
# which CI's rootfs job unpacks into staging/ the same way before the same merge.
#
# EXTENSION=<name> in env.sh makes the target staging/<pkg>/extensions/<name> instead,
# merged into extensions/<name>/: software that belongs in a system extension
# (docs/sysext.md) rather than in the image. It compiles against the same sysroot as
# everything else, but nothing image/build-rootfs.sh copies ever contains it, so no list
# of subtractions has to know about it.
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

# Built into a scratch tree and moved into place only once the build has succeeded, so a
# failed build leaves the previous one staged — rather than an empty tree, and an image
# that has silently lost the package at the next merge. Files in it belong to the
# container's users, hence the podman unshare fallback, as in tools/clean.sh.
STAGE="staging/$PKG"
BUILDING="staging/.building-$PKG"
as_owner() { "$@" 2>/dev/null || podman unshare "$@"; }
as_owner rm -rf "$BUILDING"
DEST_DIR="$BUILDING/rootfs"
[ -z "${EXTENSION:-}" ] || DEST_DIR="$BUILDING/extensions/$EXTENSION"
mkdir -p "$DEST_DIR"

# glibc itself is what fills the sysroot, and the kernel is freestanding — neither has
# one to build against.
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
    # Read-only: the sysroot is an input, and a separate tree from the DESTDIR mount
    # below, which stays writable.
    sysroot_abs=$(realpath "$SYSROOT_DIR")
    sysroot_mount=(--volume "$sysroot_abs":/usr/local/sysroot:ro
                   --env SYSROOT=/usr/local/sysroot)
fi

mkdir -p output

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
        # The vendored dependencies, for a package that has them, go in on top: cargo's
        # vendor tarballs hold ./vendor/<crate>/..., which is where the package's build
        # points cargo with --offline. Same staging directory, so an interrupted run
        # cannot leave a source tree that has the code and not its dependencies.
        if [ -n "${VENDOR_TARBALL:-}" ]; then
            tar -xf "downloads/$VENDOR_TARBALL" -C "$staging"
        fi
        mv "$staging" "$PKG_DIR/$PACKAGE"
    else
        echo "Directory $PKG_DIR/$PACKAGE already exists, skipping extraction."
    fi
    src_mount=(--volume "$PWD/$PKG_DIR/$PACKAGE":/usr/local/src)
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
    # Not a pin, but the same kind of input: every "now" a build could embed. See
    # tools/lib.sh.
    --env "SOURCE_DATE_EPOCH=$FLFS_SOURCE_DATE_EPOCH"
)
if [ -n "${LOCAL_SOURCE:-}" ]; then
    # No tarball and so no checksum: the source is this repository at whatever commit is
    # checked out, and `VERSION` is ours and means only what we say it means.
    component_env+=(--env "FLFS_ORIGIN=local")
else
    component_env+=(--env "FLFS_ORIGIN=tarball" --env "FLFS_URL=$URL" --env "FLFS_SHA256=$SHA256")
    if [ -n "${VENDOR_TARBALL:-}" ]; then
        component_env+=(--env "FLFS_VENDOR_URL=$VENDOR_URL" --env "FLFS_VENDOR_SHA256=$VENDOR_SHA256")
    fi
fi

# --network=none is the point of splitting prep out: the sources are on disk and the
# toolchain is in the image, so a compile that reaches for the internet is a bug, and
# this is what turns that from a claim into something it cannot do.
# --security-opt label=disable is for SELinux hosts (Fedora): the bind mounts are plain
# home-directory files the container's confined domain may not write, and relabelling
# them with :z would rewrite the labels of the checkout. A no-op where SELinux is off.
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
