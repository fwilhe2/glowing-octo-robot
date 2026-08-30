#!/usr/bin/env bash
# Push the OCI images this build produced to a registry, as one multi-arch image:
#
#     ./tools/publish-oci.sh                      # every publishing variant, both arches
#     ./tools/publish-oci.sh full                 # just one variant
#     TAG=v1 ./tools/publish-oci.sh               # under a name of your choosing
#     REGISTRY=localhost:5000 ./tools/publish-oci.sh
#
# What gets pushed is decided in image/variants/*.conf, not here: a variant with a
# `publish oci` line is one whose container image goes to the registry. Today that is
# `full` alone, and the compatibility point that matters is that `full` is the default
# variant — so `flfs:latest` and `flfs:<commit>` go on meaning exactly what they meant
# before variants existed, because they already have consumers. Another variant that
# starts publishing gets a repository of its own, flfs-<variant>, rather than a tag
# inside that one.
#
# It expects the archives where CI's download-artifact leaves them,
# artifacts/oci-image-<arch>/flfs-oci.tar (and flfs-<variant>-oci.tar), which is also
# where tools/fetch-image.sh puts a downloaded one. Both architectures have to be present
# for each: the point of this script is the manifest list, and a list with one entry is
# just an image with extra steps.
#
# Unlike the builder and sources images, this one is not content-addressed — it is the
# output of a build rather than an input to it, and what went into it is the whole
# repository. So the tag is the commit, and `latest` follows main.
#
# Nothing here needs skopeo or buildah. `podman load` reads the hand-written layout
# image/build-rootfs.sh produces, and podman is already the only container tool this
# repository uses.
set -euo pipefail

cd "$(dirname "$0")/.."

REGISTRY="${REGISTRY:-ghcr.io/fwilhe2/glowing-octo-robot}"

DEFAULT_VARIANT=$(./tools/variants.sh default)
if [ $# -gt 0 ]; then
    VARIANTS="$*"
else
    VARIANTS=$(./tools/variants.sh publish oci | tr '\n' ' ')
fi
[ -n "$VARIANTS" ] || { echo "error: no variant declares 'publish oci'" >&2; exit 1; }

# GITHUB_SHA in Actions, the working tree's HEAD locally. Twelve characters because
# that is long enough to be unambiguous and short enough to type.
sha="${GITHUB_SHA:-$(git rev-parse HEAD)}"
TAG="${TAG:-${sha:0:12}}"

# Also tag the list `latest`, unless something else was asked for: a moving name is
# what makes `podman run ghcr.io/.../flfs` work without looking a commit up first.
LATEST="${LATEST:-latest}"

for variant in $VARIANTS; do
    # The default variant keeps the bare names — the archive image/build-rootfs.sh wrote
    # and the repository it is published under.
    if [ "$variant" = "$DEFAULT_VARIANT" ]; then
        archive_name=flfs-oci.tar
        REPO="$REGISTRY/flfs"
    else
        archive_name=flfs-$variant-oci.tar
        REPO="$REGISTRY/flfs-$variant"
    fi

    per_arch=()
    for arch in amd64 arm64; do
        archive="artifacts/oci-image-$arch/$archive_name"
        [ -f "$archive" ] || {
            echo "error: no OCI archive for $variant/$arch at $archive" >&2
            echo "       CI's rootfs job uploads one artifact per architecture as" >&2
            echo "       oci-image-<arch>, holding every publishing variant's archive;" >&2
            echo "       download both before running this (tools/fetch-image.sh, or" >&2
            echo "       actions/download-artifact with pattern: oci-image-*)." >&2
            exit 1
        }

        # Each variant's archive carries its own ref.name annotation — flfs:latest,
        # flfs-minimal:latest — so two variants no longer collide. Two *architectures* of
        # the same variant still do, both loading as the same tag, so tag and push inside
        # this loop before the next load: by the end of it that tag means arm64 and
        # nothing should be relying on it.
        loaded=$(podman load --quiet --input "$archive" | tail -n1)
        ref=${loaded##*: }
        [ -n "$ref" ] || { echo "error: could not tell what podman loaded: $loaded" >&2; exit 1; }

        dest="$REPO:$TAG-$arch"
        podman tag "$ref" "$dest"
        podman push "$dest"
        echo ">> pushed $dest"
        per_arch+=("$dest")
    done

    # The two per-arch tags stay. They are what the list points at — a manifest list is
    # digests, not tags, but an untagged manifest is a garbage collection candidate at most
    # registries — and they are how you ask for the other architecture on purpose.
    #
    # `podman manifest create` adds to an existing list rather than replacing it, so a stale
    # one from an interrupted run would survive with only its old entries refreshed. Remove
    # it first; the same trap is handled the same way in tools/prep.sh.
    podman manifest rm "$REPO:$TAG" >/dev/null 2>&1 || true
    podman manifest create "$REPO:$TAG" "${per_arch[@]}"

    podman manifest push --all "$REPO:$TAG"
    echo ">> pushed $REPO:$TAG (manifest list)"

    if [ -n "$LATEST" ]; then
        podman manifest push --all "$REPO:$TAG" "docker://$REPO:$LATEST"
        echo ">> pushed $REPO:$LATEST (manifest list)"
    fi
done
