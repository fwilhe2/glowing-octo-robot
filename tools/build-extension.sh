#!/bin/bash
# Build a system or configuration extension for this image from a directory tree:
#
#     ./tools/build-extension.sh sysext  <name> <dir>   # → output/extensions/<name>.raw
#     ./tools/build-extension.sh confext <name> <dir>   # → output/confexts/<name>.raw
#
# <dir> is laid out like the target: usr/ (and opt/) for a sysext, etc/ for a confext.
# The image is made by image/build-extension.sh in the image-assembly container, which is
# where the root image is made too; see that script for what goes into it. Put the result
# in a guest's /var/lib/extensions or /var/lib/confexts and it is merged at the next boot
# (or by `systemd-sysext refresh` / `systemd-confext refresh` right away).
set -euo pipefail
cd "$(dirname "$0")/.."
source tools/lib.sh

class="${1:?usage: $0 sysext|confext <name> <dir>}"
name="${2:?usage: $0 sysext|confext <name> <dir>}"
dir="${3:?usage: $0 sysext|confext <name> <dir>}"
[ -d "$dir" ] || { echo "error: $dir is not a directory" >&2; exit 1; }

mkdir -p output
# Rebuilt every time, as tools/build-image.sh does: image/files is COPYed into it, and the
# extension's level is read from there.
podman build -q -t rootfs-builder -f image/Containerfile . > /dev/null
podman run --rm --security-opt label=disable \
    -e SOURCE_DATE_EPOCH="$FLFS_SOURCE_DATE_EPOCH" ${LEVEL:+-e LEVEL="$LEVEL"} \
    --volume "$(realpath "$dir")":/usr/local/src:ro \
    --volume "$PWD/output":/usr/local/output \
    rootfs-builder /usr/local/bin/build-extension.sh "$class" "$name"
