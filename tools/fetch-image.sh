#!/usr/bin/env bash
# Download a bootable combination of the latest rootfs image + kernel into
# output/boot-image/, with the system extensions built in the same run beside them.
#
# Both come out of the same CI run, because they have to match: the kernel is a package
# in this repo (kernel/), and its container.config fragment is what makes the image able
# to run containers at all. Pulling a kernel from anywhere else gives you a guest that
# boots and then quietly has no `memory` cgroup controller, no overlayfs and no veth.
#
# By default it grabs the latest *successful* CI run, for the host's own architecture.
# Override any of:
#   ARCH         amd64 or arm64 (default the host's own architecture)
#   ROOTFS_RUN   pin a specific glowing-octo-robot run id
#   OUT          output directory (default output/boot-image, or output/boot-image-$ARCH
#                when ARCH is overridden away from the host's own)
#
# Examples:
#   ./tools/fetch-image.sh
#   ARCH=arm64 ./tools/fetch-image.sh
#   ROOTFS_RUN=29703135782 ./tools/fetch-image.sh
set -euo pipefail

cd "$(dirname "$0")/.."
source tools/lib.sh

REPO="fwilhe2/glowing-octo-robot"

# Defaults to the host's own architecture. ci.yml builds and boot-tests both amd64 and
# arm64 in every run, tagging each artifact with the arch that produced it, so this has
# to pick one. Both uname's spelling (x86_64/aarch64) and this repo's (amd64/arm64) are
# accepted.
ARCH=$(normalize_arch "${ARCH:-}")

# Only suffix the default output directory when ARCH was overridden away from the
# host's own, so the common case — fetch, then boot, both with no ARCH set — still lands
# in plain output/boot-image on both sides.
host_arch=$(normalize_arch)
if [ "$ARCH" = "$host_arch" ]; then
    OUT="${OUT:-output/boot-image}"
else
    OUT="${OUT:-output/boot-image-$ARCH}"
fi

command -v gh >/dev/null || { echo "error: gh CLI not found" >&2; exit 1; }

mkdir -p "$OUT"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

RUN="${ROOTFS_RUN:-$(gh run list -R "$REPO" --workflow ci.yml --status success -L 1 \
                       --json databaseId -q '.[0].databaseId')}"
[ -n "$RUN" ] || { echo "error: no successful run found" >&2; exit 1; }

echo ">> rootfs ($ARCH): $REPO run $RUN (artifact: rootfs.erofs-$ARCH)"
gh run download "$RUN" -R "$REPO" -n "rootfs.erofs-$ARCH" -D "$tmp/rootfs"

# The kernel package artifact rather than the assembled rootfs one: it is a tar, so the
# bzImage comes out byte-for-byte, and it is the same artifact the CI boot job uses.
echo ">> kernel ($ARCH): $REPO run $RUN (artifact: package-kernel-$ARCH)"
gh run download "$RUN" -R "$REPO" -n "package-kernel-$ARCH" -D "$tmp/kernel"
tar xf "$tmp/kernel/kernel.tar" -C "$tmp/kernel" rootfs/boot/bzImage

# The system extensions built in the same run (docs/sysext.md), laid out next to the
# image as tools/build-image.sh lays them out next to its own: extensions/ and confexts/.
# Optional — a run from before they existed has none, and only tools/k8s-demo.sh wants one.
echo ">> extensions ($ARCH): $REPO run $RUN (artifact: extensions-$ARCH)"
have_extensions=0
if gh run download "$RUN" -R "$REPO" -n "extensions-$ARCH" -D "$tmp/extensions" 2>/dev/null; then
    have_extensions=1
else
    echo "   (none in this run)"
fi

# Into $OUT only once everything is downloaded, so a failed fetch leaves the previous
# image as it was rather than a new rootfs beside an old kernel: the image and the kernel
# arguments that carry its dm-verity root hash, the kernel, the extensions, and the run
# they came from.
cp "$tmp/rootfs/rootfs.erofs" "$tmp/rootfs/rootfs.cmdline" "$OUT/"
cp "$tmp/kernel/rootfs/boot/bzImage" "$OUT/bzImage"
if [ "$have_extensions" = 1 ]; then
    rm -rf "$OUT/extensions" "$OUT/confexts"
    cp -r "$tmp/extensions"/. "$OUT/"
fi
echo "$RUN" > "$OUT/ci-run"

echo
echo "Downloaded into $OUT/:"
ls -la "$OUT/rootfs.erofs" "$OUT/rootfs.cmdline" "$OUT/bzImage" "$OUT"/extensions/*.raw "$OUT"/confexts/*.raw 2>/dev/null || true
if [ "$ARCH" = "$host_arch" ]; then
    echo "Boot it with: ./tools/boot-qemu.sh"
else
    echo "Boot it with: ARCH=$ARCH ./tools/boot-qemu.sh"
fi
