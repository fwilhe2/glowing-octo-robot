#!/usr/bin/env bash
# Download a bootable combination of the latest rootfs image + kernel into ./boot-image/.
#
# By default it grabs the latest *successful* CI run from each repo. Override any of:
#   KERNEL_VERSION   kernel artifact to pull (default 6.12.96)
#   ROOTFS_RUN       pin a specific glowing-octo-robot run id
#   KERNEL_RUN       pin a specific potential-spork run id
#   OUT              output directory (default boot-image)
#
# Examples:
#   ./fetch-image.sh
#   KERNEL_VERSION=7.1.4 ./fetch-image.sh
#   ROOTFS_RUN=29703135782 KERNEL_RUN=29703191432 ./fetch-image.sh
set -euo pipefail

ROOTFS_REPO="fwilhe2/glowing-octo-robot"
KERNEL_REPO="fwilhe2/potential-spork"
KERNEL_VERSION="${KERNEL_VERSION:-6.12.96}"
OUT="${OUT:-boot-image}"

command -v gh >/dev/null || { echo "error: gh CLI not found" >&2; exit 1; }

latest_success_run() { # repo [workflow]
  local repo="$1" wf="${2:-}"
  if [ -n "$wf" ]; then
    gh run list -R "$repo" --workflow "$wf" --status success -L 1 --json databaseId -q '.[0].databaseId'
  else
    gh run list -R "$repo" --status success -L 1 --json databaseId -q '.[0].databaseId'
  fi
}

mkdir -p "$OUT"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

ROOTFS_RUN="${ROOTFS_RUN:-$(latest_success_run "$ROOTFS_REPO" ci.yml)}"
[ -n "$ROOTFS_RUN" ] || { echo "error: no successful rootfs run found" >&2; exit 1; }
echo ">> rootfs: $ROOTFS_REPO run $ROOTFS_RUN (artifact: rootfs.ext4)"
gh run download "$ROOTFS_RUN" -R "$ROOTFS_REPO" -n rootfs.ext4 -D "$tmp/rootfs"
cp "$(find "$tmp/rootfs" -type f | head -1)" "$OUT/rootfs.ext4"

KERNEL_RUN="${KERNEL_RUN:-$(latest_success_run "$KERNEL_REPO")}"
[ -n "$KERNEL_RUN" ] || { echo "error: no successful kernel run found" >&2; exit 1; }
echo ">> kernel: $KERNEL_REPO run $KERNEL_RUN (artifact: bzImage-$KERNEL_VERSION)"
gh run download "$KERNEL_RUN" -R "$KERNEL_REPO" -n "bzImage-$KERNEL_VERSION" -D "$tmp/kernel"
cp "$(find "$tmp/kernel" -type f | head -1)" "$OUT/bzImage"

echo
echo "Downloaded into $OUT/:"
ls -la "$OUT/rootfs.ext4" "$OUT/bzImage"
echo "Boot it with: ./boot-qemu.sh"
