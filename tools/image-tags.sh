#!/usr/bin/env bash
# Print the fully qualified reference of one of the two build-input images:
#
#     ./tools/image-tags.sh builder    # the toolchain everything compiles in
#     ./tools/image-tags.sh sources    # every pinned tarball, FROM scratch
#
# Both tags are content hashes, so the same checkout always names the same image and CI
# and a local tree agree without having to coordinate. Override the registry with
# REGISTRY= (localhost, for instance, to work entirely offline).
set -euo pipefail

cd "$(dirname "$0")/.."

REGISTRY="${REGISTRY:-ghcr.io/fwilhe2/glowing-octo-robot}"

# The builder is compiled software and every build here is native, so there is one per
# architecture and the tag has to say which — two runners pushing the same tag would
# clobber each other. The sources image is data, so it is one manifest list for both.
ARCH="${ARCH:-$(uname -m)}"
case "$ARCH" in
    x86_64|amd64)  ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) echo "error: unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

case "${1:-}" in
    builder)
        # Everything that changes what is installed in the image, and nothing else: the
        # dependency list, how it is installed, and the entrypoint baked in beside it.
        hash=$(cat builder/Containerfile builder/deps.txt builder/build-package.sh | sha256sum)
        echo "$REGISTRY/builder:${hash:0:16}-$ARCH"
        exit 0
        ;;
    sources)
        # Every pinned version and its checksum. A version bump changes the tag, which is
        # the point — the image contents changed. Nothing else in env.sh matters here:
        # a changed URL that still yields the same bytes is the same image.
        hash=$(for e in packages/*/env.sh; do
                   ( PKG=$(basename "$(dirname "$e")"); . "$e"
                     printf '%s %s %s\n' "$PKG" "$TARBALL" "$SHA256" )
               done | sort | sha256sum)
        ;;
    *)
        echo "usage: $0 builder|sources" >&2
        exit 1
        ;;
esac

echo "$REGISTRY/${1}:${hash:0:16}"
