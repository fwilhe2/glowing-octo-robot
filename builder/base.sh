#!/bin/bash
# Build the base image every package builder derives from, and create the shared
# staging directories. The build context is the repository root, so run it from there
# — ../build.sh does.
set -euo pipefail

# Everything here builds natively — no cross-compilation, no QEMU-emulated podman
# builds — so the toolchain package names Containerfile needs are whatever matches the
# host this is running on. Debian spells the amd64 triplet with a hyphen instead of the
# GNU triplet's underscore (x86-64-linux-gnu, not x86_64-linux-gnu); arm64's triplet
# (aarch64-linux-gnu) needs no such translation.
case "$(uname -m)" in
    x86_64)  deb_arch_triple=x86-64-linux-gnu ;;
    aarch64) deb_arch_triple=aarch64-linux-gnu ;;
    *) echo "error: unsupported host architecture: $(uname -m) (expected x86_64 or aarch64)" >&2
       exit 1 ;;
esac

podman build -t localhost/abstract-lfs-builder \
    --build-arg "DEB_ARCH_TRIPLE=$deb_arch_triple" \
    -f builder/base.Containerfile .

mkdir -p rootfs output
