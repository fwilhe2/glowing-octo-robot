#!/usr/bin/env bash
# Download a bootable combination of the latest rootfs image + kernel into
# output/boot-image/.
#
# Both come out of the same CI run, because they have to match: the kernel is a package
# in this repo (kernel/), and its container.config fragment is what makes the image able
# to run containers at all. Pulling a kernel from anywhere else gives you a guest that
# boots and then quietly has no `memory` cgroup controller, no overlayfs and no veth.
#
# By default it grabs the latest *successful* CI run. Override any of:
#   ROOTFS_RUN   pin a specific glowing-octo-robot run id
#   OUT          output directory (default output/boot-image)
#
# Examples:
#   ./tools/fetch-image.sh
#   ROOTFS_RUN=29703135782 ./tools/fetch-image.sh
set -euo pipefail

cd "$(dirname "$0")/.."

REPO="fwilhe2/glowing-octo-robot"
OUT="${OUT:-output/boot-image}"

command -v gh >/dev/null || { echo "error: gh CLI not found" >&2; exit 1; }

mkdir -p "$OUT"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

RUN="${ROOTFS_RUN:-$(gh run list -R "$REPO" --workflow ci.yml --status success -L 1 \
                       --json databaseId -q '.[0].databaseId')}"
[ -n "$RUN" ] || { echo "error: no successful run found" >&2; exit 1; }

echo ">> rootfs: $REPO run $RUN (artifact: rootfs.ext4)"
gh run download "$RUN" -R "$REPO" -n rootfs.ext4 -D "$tmp/rootfs"
cp "$(find "$tmp/rootfs" -type f | head -1)" "$OUT/rootfs.ext4"

# The kernel package artifact rather than the assembled rootfs one: it is a tar, so the
# bzImage comes out byte-for-byte, and it is the same artifact the CI boot job uses.
echo ">> kernel: $REPO run $RUN (artifact: package-kernel)"
gh run download "$RUN" -R "$REPO" -n package-kernel -D "$tmp/kernel"
tar xf "$tmp/kernel/kernel.tar" -C "$tmp/kernel" rootfs/boot/bzImage
cp "$tmp/kernel/rootfs/boot/bzImage" "$OUT/bzImage"

echo
echo "Downloaded into $OUT/:"
ls -la "$OUT/rootfs.ext4" "$OUT/bzImage"
echo "Boot it with: ./tools/boot-qemu.sh"
