#!/bin/bash
# Build everything and assemble the images, locally, in one go:
#
#     ./tools/build-image.sh                 # glibc, kernel, every package, then ext4 + oci
#     ./tools/build-image.sh --clean         # delete rootfs/ first (after version bumps)
#     ./tools/build-image.sh --image-only    # skip the packages, just re-assemble the images
#     ./tools/build-image.sh --flavour ext4  # only one of ext4 / oci
#     ./tools/build-image.sh --skip kernel,systemd   # leave packages out of this run
#     ./tools/build-image.sh --only strace   # build just these packages, then the images
#
# Packages are built one after another: they all install into the shared rootfs/ tree, so
# running them in parallel would race. glibc goes first because everything else compiles
# against it; the rest follow in alphabetical order, which is fine since CI builds them
# independently against a glibc-only sysroot too.
#
# ADDITIONAL FILES: anything under extra/ (gitignored, create it yourself) is copied over
# the assembled image as-is, for both flavours. Lay it out like the target filesystem:
#
#     extra/usr/bin/my-static-strace
#     extra/etc/motd
#     extra/root/.bashrc
#
# Extra *software* built from source belongs in packages/ instead, like any other package:
# once it has an env.sh + build.sh, this script picks it up automatically.
#
# A long run: use `run_in_background` or a terminal multiplexer.
set -euo pipefail
cd "$(dirname "$0")/.."
source tools/lib.sh

clean=0 image_only=0 flavours="ext4 oci" skip="" only=""
while [ $# -gt 0 ]; do
    case "$1" in
        --clean)      clean=1 ;;
        --image-only) image_only=1 ;;
        --flavour)    flavours="${2:?--flavour needs ext4 or oci}"; shift ;;
        --skip)       skip="${2:?--skip needs a comma-separated list}"; shift ;;
        --only)       only="${2:?--only needs a comma-separated list}"; shift ;;
        -h|--help)    sed -n '2,/^set -e/p' "$0" | sed '$d;s/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
    esac
    shift
done

for f in $flavours; do
    case "$f" in ext4|oci) ;; *) echo "error: unknown flavour '$f'" >&2; exit 2 ;; esac
done

if [ "$clean" = 1 ]; then
    echo "==> removing rootfs/"
    # Files were created by the container's root, which is a subuid from out here.
    podman unshare rm -rf rootfs 2>/dev/null || rm -rf rootfs
fi

if [ "$image_only" = 0 ]; then
    all=$(all_packages)
    if [ -n "$only" ]; then
        order=$(echo "$only" | tr ',' ' ')
    else
        # glibc must be first; everything else in listing order.
        order="glibc $(echo "$all" | grep -vx glibc | tr '\n' ' ')"
    fi
    skip_list=",$skip,"
    total=$(echo $order | wc -w) n=0
    for pkg in $order; do
        n=$((n + 1))
        if [[ "$skip_list" == *",$pkg,"* ]]; then
            echo "==> [$n/$total] $pkg (skipped)"
            continue
        fi
        echo "==> [$n/$total] $pkg  ($(date +%H:%M:%S))"
        ./build.sh "$pkg"
    done
fi

if [ ! -e rootfs/usr/lib/libc.so.6 ]; then
    echo "error: rootfs/ has no glibc; nothing to assemble" >&2
    exit 1
fi

echo "==> checking the staging tree"
./test/check-rootfs-deps.sh rootfs || echo "warning: unresolved libraries (see above)" >&2

echo "==> assembling images"
mkdir -p output extra
# Rebuilt every time: image/files is COPYed into it, so a stale image ships a stale /etc.
podman build -q -t rootfs-builder -f image/Containerfile .

build=$(git rev-parse HEAD 2>/dev/null || echo local)
for f in $flavours; do
    echo "==> image: $f"
    podman run --rm --security-opt label=disable \
        -e FLFS_BUILD="$build" \
        --volume "$PWD/rootfs":/usr/local/src \
        --volume "$PWD/extra":/extra:ro \
        --volume "$PWD/output":/usr/local/output \
        rootfs-builder /usr/local/bin/build-rootfs.sh "$f"
done

echo
echo "done:"
ls -lh output/rootfs.ext4 output/flfs-oci.tar 2>/dev/null || true
echo "boot it:  ./tools/boot-qemu.sh   (or ./test/systemd.sh output/rootfs.ext4 rootfs/boot/bzImage)"
