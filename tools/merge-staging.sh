#!/bin/bash
# Rebuild rootfs/ and extensions/ from every package's own staging tree:
#
#     ./tools/merge-staging.sh
#
# Each package installs into staging/<pkg>/, laid out like its CI artifact: rootfs/...
# for the base, extensions/<name>/... for a package with EXTENSION=. Nothing installs
# into rootfs/ any more; it is *derived*, by this script, which root build.sh runs after
# every package and CI's rootfs job runs after unpacking the artifacts into staging/
# the same way. One script for both is the point: the collision check and the unpack
# order used to exist only in ci.yml, so a local build could ship a file two packages
# installed, and get whichever was built last.
#
# What that buys over the cumulative rootfs/ it replaces:
#
#   - a rebuilt package replaces its files instead of adding to them, so a file a new
#     version stopped installing is gone, rather than staged until somebody deletes
#     rootfs/ and rebuilds everything from glibc;
#   - which package installed a file is a question with an answer: the one whose
#     staging/ has it;
#   - two packages installing one path fail the merge, here and in CI alike.
#
# The copies are --reflink=auto: on btrfs or XFS a copy-on-write clone that costs nothing,
# on ext4 a real copy. Not hardlinks, which would be as fast everywhere but would make an
# in-place edit of a file in rootfs/ an edit of the package's staging tree too.
set -euo pipefail

cd "$(dirname "$0")/.."
source tools/lib.sh

STAGING=staging
STAMP=$STAGING/.merged

[ -d "$STAGING" ] || { echo "error: no $STAGING/ — build a package first (./build.sh glibc)" >&2; exit 1; }

# A rootfs/ this script did not make is a checkout from before staging/ existed, holding
# hours of builds that are in no staging tree. Deleting it to merge two packages would
# leave an image of two packages, so say what happened instead.
if [ ! -e "$STAMP" ] && [ -n "$(ls -A rootfs extensions 2>/dev/null)" ]; then
    echo "error: rootfs/ or extensions/ exists but was not made by $0." >&2
    echo "       Packages now install into staging/<pkg>/ and rootfs/ is merged from them" >&2
    echo "       (CLAUDE.md, 'How a package build works'). An older tree has no record of" >&2
    echo "       which package installed what, so it cannot be split; rebuild instead:" >&2
    echo "           ./tools/clean.sh && ./tools/build-image.sh" >&2
    exit 1
fi

# Files the container's users created are subuids from out here; podman unshare is the
# same fallback tools/clean.sh uses.
as_owner() { "$@" 2>/dev/null || podman unshare "$@"; }

trees=$(find "$STAGING" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | sort)

# A staging tree holds rootfs/, extensions/ or both, and nothing else: anything beside
# them would be copied to the top of the checkout by the merge below.
for t in $trees; do
    extra=$(find "$t" -mindepth 1 -maxdepth 1 ! -name rootfs ! -name extensions)
    if [ -n "$extra" ]; then
        echo "error: $t holds more than rootfs/ and extensions/:" >&2
        echo "$extra" | sed 's/^/    /' >&2
        exit 1
    fi
done

# Every path two trees both install. Directories are shared by design, and so are the
# merged-/usr symlinks (bin -> usr/bin and friends), which builder/build-package.sh
# creates identically in every tree and extension; anything else is a real collision.
# e2fsprogs and util-linux both shipped /usr/bin/fsck until this existed in CI.
dups=$(for t in $trees; do
           as_owner find "$t" -mindepth 1 ! -type d -printf "%P $(basename "$t")\n"
       done | sort | awk '{ n[$1]++; p[$1] = p[$1] " " $2 }
                          END { for (f in n) if (n[f] > 1) print f ":" p[f] }' | sort)
dups=$(grep -vE '^(rootfs|extensions/[^/]+)/(bin|lib|lib64|sbin|usr/sbin):' <<< "$dups" || true)
if [ -n "$dups" ]; then
    echo "error: more than one package installs these files:" >&2
    echo "$dups" | sed 's/^/    /' >&2
    echo "Fix it in one of the packages (e2fsprogs is built --disable-fsck for this)," >&2
    echo "never by ordering: the image would depend on which was copied last." >&2
    exit 1
fi

as_owner rm -rf rootfs extensions
# In sorted order, so the only things more than one tree provides — directories, whose
# modes then come from the last tree to have them, and the identical merged-/usr links —
# land the same way on every machine.
for t in $trees; do
    as_owner cp -a --reflink=auto "$t"/. ./
done
mkdir -p rootfs
touch "$STAMP"
