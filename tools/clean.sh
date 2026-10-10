#!/usr/bin/env bash
# Delete what building, testing and fetching have left behind:
#
#     ./tools/clean.sh               # build state: rootfs/, unpacked sources, output/, ...
#     ./tools/clean.sh --downloads   # ...and the source tarballs in downloads/
#     ./tools/clean.sh --images      # ...and this repo's podman images that are out of date
#     ./tools/clean.sh --all         # all of the above, current images included
#     ./tools/clean.sh -n [...]      # say what would go, and how big it is; delete nothing
#
# The default is everything a rebuild recreates without the network: the cumulative
# staging tree (rootfs/, which CLAUDE.md tells you to delete after a version bump
# anyway), the glibc-only sysroot, every unpacked source tree under packages/ (the
# kernel's alone is several GB), built images, test logs and fetched CI artifacts.
#
# The rest is opt-in because getting it back costs a download. downloads/ is refilled by
# tools/prep.sh from the sources image or upstream. --images removes builder and sources
# images whose tag no longer matches tools/image-tags.sh — every builder/deps.txt edit or
# version bump leaves one behind, and a builder is gigabytes — plus the image-assembly
# container and the `flfs` image test/oci.sh loads, which are rebuilt on every run. The
# *current* builder and sources images stay unless --all says otherwise, since those are
# what the next ./build.sh would pull.
#
# Never touched: extra/ (your own additions, see tools/build-image.sh), anything git
# tracks, and podman images that are not this repository's. A path is only deleted if
# git agrees it is ignored, so a tracked file can never match a pattern by accident.
set -euo pipefail

cd "$(dirname "$0")/.."
source tools/lib.sh

dry=0 downloads=0 images=0 current=0
while [ $# -gt 0 ]; do
    case "$1" in
        -n|--dry-run) dry=1 ;;
        --downloads)  downloads=1 ;;
        --images)     images=1 ;;
        --all)        downloads=1 images=1 current=1 ;;
        -h|--help)    sed -n '2,/^set -e/p' "$0" | sed '$d;s/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
    esac
    shift
done

paths=(rootfs sysroot glibc-package output artifacts packages/*/*-[0-9]*/ packages/*/.extracting)
[ "$downloads" = 1 ] && paths+=(downloads)

# Files a build wrote are owned by the container's users, which are subuids from out
# here, so a plain rm can fail on them — the same fallback tools/build-image.sh --clean
# uses.
remove() {
    rm -rf "$1" 2>/dev/null || podman unshare rm -rf "$1"
}

for p in "${paths[@]}"; do
    p=${p%/}
    [ -e "$p" ] || continue
    if ! git check-ignore -q "$p"; then
        echo "skip   $p (not ignored by git)" >&2
        continue
    fi
    size=$(du -sh "$p" 2>/dev/null | cut -f1)
    if [ "$dry" = 1 ]; then
        echo "would remove  $size  $p"
    else
        echo "removing  $size  $p"
        remove "$p"
    fi
done

[ "$images" = 1 ] || exit 0
if ! command -v podman >/dev/null; then
    echo "note: podman not found, no images to remove" >&2
    exit 0
fi

# This repository's images are the ones under the registry tools/image-tags.sh names,
# plus the two local tags image assembly and test/oci.sh create. Asked of image-tags.sh
# rather than spelled out, so REGISTRY= works the same here as there.
builder=$(./tools/image-tags.sh builder)
sources=$(./tools/image-tags.sh sources)
registry=${builder%/builder:*}

while read -r ref id size; do
    case "$ref" in
        "$registry"/builder:*|"$registry"/sources:*)
            if [ "$current" = 0 ] && { [ "$ref" = "$builder" ] || [ "$ref" = "$sources" ]; }; then
                continue
            fi ;;
        localhost/rootfs-builder:*|localhost/flfs:*) ;;
        *) continue ;;
    esac
    if [ "$dry" = 1 ]; then
        echo "would remove  $size  $ref"
    else
        echo "removing  $size  $ref"
        # By name, not id: one id can carry several tags, and only this one is ours to drop.
        # A manifest list (the sources image) is removed the same way.
        podman rmi "$ref" >/dev/null || podman manifest rm "$ref" >/dev/null || true
    fi
done < <(podman images --format '{{.Repository}}:{{.Tag}} {{.ID}} {{.Size}}' | sed 's/ \([0-9.]*\) \([kMG]*B\)$/ \1\2/')

# What untagging leaves behind: layers no tag reaches any more. Only dangling ones, which
# by definition nothing — this repository's or anyone else's — can still be using.
if [ "$dry" = 0 ]; then
    podman image prune -f >/dev/null
fi
