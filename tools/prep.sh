#!/usr/bin/env bash
# The network half of a build, on its own:
#
#     ./tools/prep.sh            # make sure both images exist locally, building if needed
#     ./tools/prep.sh --push     # ...and push them to the registry
#
# After this succeeds a build needs nothing from the internet, which is why build.sh runs
# the compile with --network=none. Run it before going offline, or let build.sh call it.
#
# Both images are content-addressed (tools/image-tags.sh), so "make sure it exists" is
# pull-then-build-on-miss: a tag that is already in the registry is never rebuilt.
set -euo pipefail

cd "$(dirname "$0")/.."

push=
[ "${1:-}" = "--push" ] && { push=1; shift; }
# CI splits the two: the builder is built once per architecture on a native runner, the
# sources image once for both. Locally the default does whichever is missing.
want="${1:-both}"

builder=$(./tools/image-tags.sh builder)
sources=$(./tools/image-tags.sh sources)

have() { podman image exists "$1"; }
pull() { podman pull --quiet "$1" >/dev/null 2>&1; }

if [ "$want" = sources ]; then
    : # skip the builder entirely
elif have "$builder" || pull "$builder"; then
    echo ">> builder: $builder (have it)"
else
    echo ">> builder: $builder (building)"
    podman build -t "$builder" -f builder/Containerfile .
fi

# Having the image is not the same as having the tarballs where a build can see them, so
# unpack it into downloads/ afterwards. This is what makes the registry the first place a
# source is looked for and the internet the fallback, rather than the other way round.
extract_sources() {
    local ctr
    ctr=$(podman create "$sources" /nonexistent)
    mkdir -p downloads
    podman cp "$ctr:/sources/." downloads/
    podman rm "$ctr" >/dev/null
}

if [ "$want" = builder ]; then
    :
elif have "$sources" || pull "$sources"; then
    echo ">> sources: $sources (have it)"
    extract_sources
else
    echo ">> sources: $sources (building)"
    ./tools/fetch-sources.sh
    # Only the pinned tarballs go in. downloads/ is cumulative and keeps whatever an
    # earlier checkout fetched — three kernel releases, say — and none of that belongs
    # in an image whose tag claims to describe exactly one set of versions.
    stage=$(mktemp -d)
    trap 'rm -rf "$stage"' EXIT
    mkdir -p "$stage/sources"
    for e in packages/*/env.sh; do
        ( PKG=$(basename "$(dirname "$e")"); . "$e"
          cp "downloads/$TARBALL" "$stage/sources/$TARBALL" )
    done
    printf 'FROM scratch\nCOPY sources /sources\n' > "$stage/Containerfile"
    # A manifest list covering both architectures, from one build. There is nothing to
    # emulate — the image has no RUN, only a COPY of the same bytes — so this costs
    # nothing and saves storing 450 MB of tarballs once per architecture.
    podman manifest create "$sources" 2>/dev/null || true
    podman build --manifest "$sources" --platform linux/amd64,linux/arm64 \
        -f "$stage/Containerfile" "$stage"
fi

if [ -n "$push" ]; then
    [ "$want" = sources ] || podman push "$builder"
    [ "$want" = builder ] || podman manifest push --all "$sources"
fi

[ "$want" = sources ] || echo "$builder"
[ "$want" = builder ] || echo "$sources"
