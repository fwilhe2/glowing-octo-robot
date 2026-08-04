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

# A manifest list and a plain image do not take the same push verb, and which one is
# under a given name is not a thing to assume: the sources image is *built* as a list,
# but `podman pull` of a list gives you only the entry matching this host, so the same
# tag is a list here and an image there. Ask instead.
push_image() {
    if podman manifest inspect "$1" >/dev/null 2>&1; then
        podman manifest push --all "$1"
    else
        podman push "$1"
    fi
}

# Whether the registry already had it, which is the same question as whether there is
# anything to push. Content-addressed tags make that exact: a tag that resolved is by
# definition the image we would have built, so pushing it again is at best wasted work.
# It is also actively wrong for the sources image — `podman pull` of a manifest list
# gives you the one image matching this host, not the list, so a later
# `podman manifest push` fails with "image is not a manifest list".
builder_pulled=
sources_pulled=

if [ "$want" = sources ]; then
    : # skip the builder entirely
elif have "$builder"; then
    echo ">> builder: $builder (already local)"
elif pull "$builder"; then
    echo ">> builder: $builder (pulled)"
    builder_pulled=1
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
elif have "$sources"; then
    echo ">> sources: $sources (already local)"
    extract_sources
elif pull "$sources"; then
    echo ">> sources: $sources (pulled)"
    sources_pulled=1
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
    #
    # Two traps here, both of which produce a list with an entry for this host only and
    # no complaint — and the failure lands on whichever architecture is missing, at pull
    # time, in a different job:
    #
    #   - --manifest creates the list itself, so do not `podman manifest create` first.
    #     An existing list is added to rather than replaced, so a stale one from an
    #     interrupted run survives with only its old entry refreshed.
    #   - a cached build short-circuits to the host's image and never produces the other
    #     platform. --no-cache is what stops that, and it costs nothing worth having:
    #     this image is one COPY of files already on disk.
    podman manifest rm "$sources" >/dev/null 2>&1 || true
    podman build --no-cache --manifest "$sources" --platform linux/amd64,linux/arm64 \
        -f "$stage/Containerfile" "$stage"
fi

if [ -n "$push" ]; then
    if [ "$want" != sources ] && [ -z "$builder_pulled" ]; then
        push_image "$builder"
    fi
    if [ "$want" != builder ] && [ -z "$sources_pulled" ]; then
        push_image "$sources"
    fi
fi

[ "$want" = sources ] || echo "$builder"
[ "$want" = builder ] || echo "$sources"
