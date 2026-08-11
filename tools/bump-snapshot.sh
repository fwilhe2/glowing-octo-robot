#!/usr/bin/env bash
# Move both Debian containers to a new snapshot date:
#
#     ./tools/bump-snapshot.sh              # the newest dated sid image Debian publishes
#     ./tools/bump-snapshot.sh 20260907     # a particular one
#
# This is tools/bump-version.sh for the toolchain, and it exists for the same reason: the
# pin is two values that have to agree, and a bump that writes one of them is a bump that
# has broken something quietly. There it is VERSION and SHA256; here it is the snapshot
# date — which drives both the base image tag and the apt sources line — and the digest
# that base image tag resolves to. A date without its digest is a floating pin wearing a
# hash; a digest without its date means apt fetches one day's packages onto another day's
# base.
#
# Both Containerfiles are rewritten together. They are pinned to the same day on purpose:
# builder/Containerfile decides what the binaries are compiled by, image/Containerfile
# decides what the shipped bytes are (mkfs.ext4 and strip), and two dates would mean two
# answers to "which Debian was this built against" for one image.
#
# What this does not do is decide whether the new toolchain is any good. That is CI's job,
# and a real one: changing these files changes the builder tag, so the builder job rebuilds
# from the snapshot rather than pulling a cached image, and every package after it is
# recompiled because tools/image-tags.sh's builder reference is in their cache keys.
set -euo pipefail

cd "$(dirname "$0")/.."

# The registry the official images live in, and the archive apt is pointed at. Named here
# rather than inline because the verification at the bottom has to ask the same two
# services the Containerfiles will.
REGISTRY_API="https://registry-1.docker.io/v2/library/debian"
AUTH="https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/debian:pull"
HUB_TAGS="https://hub.docker.com/v2/repositories/library/debian/tags?page_size=100&name=sid-"
SNAPSHOT_ARCHIVE="http://snapshot.debian.org/archive/debian"

BUILDER=builder/Containerfile
IMAGE=image/Containerfile

# Both Containerfiles compose the apt URL as "${SNAPSHOT}T000000Z". The verification below
# has to ask for the same instant they will, so this is one string in two places and they
# have to be changed together.
timestamp_for() { printf '%sT000000Z' "$1"; }

usage() { sed -n '2,6p' "$0" | sed 's/^# \?//'; }

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    -*) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
esac

NEW="${1:-}"

# What is pinned now, read out of the file rather than passed in: this script is also what
# CI calls, and the workflow should not have to know the format.
current=$(sed -n -E 's|^ARG SNAPSHOT=([0-9]{8}).*|\1|p' "$BUILDER" | head -n1)
[ -n "$current" ] || {
    echo "error: no 'ARG SNAPSHOT=<yyyymmdd>' line in $BUILDER" >&2
    exit 1
}

# Newest published dated tag, when no date was asked for. Docker Hub returns tags
# newest-first, so page one is enough — but sort anyway rather than trusting the ordering,
# because a wrong answer here is a silent downgrade. `sid-<date>-slim` and friends are
# excluded by requiring the suffix to be all digits.
if [ -z "$NEW" ]; then
    NEW=$(curl -fsS --retry 3 "$HUB_TAGS" \
        | jq -r '.results[].name | select(test("^sid-[0-9]{8}$"))' \
        | sed 's/^sid-//' | sort | tail -n1)
    [ -n "$NEW" ] || { echo "error: no dated sid tags found on Docker Hub" >&2; exit 1; }
fi

[[ "$NEW" =~ ^[0-9]{8}$ ]] || { echo "error: '$NEW' is not a yyyymmdd date" >&2; exit 2; }

if [ "$NEW" = "$current" ]; then
    echo "debian snapshot: already pinned to $current, nothing to do"
    exit 0
fi

# A downgrade is never what was meant, and the workflow calling this passes whatever the
# checker found — so refuse rather than trust the caller.
if [ "$(printf '%s\n%s\n' "$current" "$NEW" | sort | tail -n1)" = "$current" ]; then
    echo "error: $NEW is older than the pinned $current; refusing to move backwards" >&2
    exit 1
fi

# Resolve the tag to a digest, without pulling 120 MB to find out.
#
# It has to be the digest of the *index* — the multi-architecture manifest list. One FROM
# line serves both the amd64 and arm64 builder jobs, so pinning a platform manifest by
# mistake produces an image that builds on one runner and dies on the other, with nothing
# in the error naming the cause. The Accept header therefore lists the single-platform
# media types as well: asking only for index types would make a platform manifest a 404
# and lose the ability to say what went wrong.
echo "debian snapshot: resolving debian:sid-$NEW"
token=$(curl -fsS --retry 3 "$AUTH" | jq -r .token)
[ -n "$token" ] && [ "$token" != null ] || { echo "error: could not get a registry token" >&2; exit 1; }

headers=$(curl -fsSI --retry 3 \
    -H "Authorization: Bearer $token" \
    -H 'Accept: application/vnd.oci.image.index.v1+json' \
    -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
    -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
    "$REGISTRY_API/manifests/sid-$NEW") || {
        echo "error: debian:sid-$NEW is not in the registry" >&2
        exit 1
    }

# Header names are case-insensitive per RFC 9110 and servers disagree in practice, hence
# the I flag rather than matching what Docker Hub happens to send today.
digest=$(printf '%s\n' "$headers" | tr -d '\r' | sed -n 's/^docker-content-digest: //Ip')
media=$( printf '%s\n' "$headers" | tr -d '\r' | sed -n 's/^content-type: //Ip')

[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
    echo "error: the registry returned no usable digest for sid-$NEW (got '${digest:-none}')" >&2
    exit 1
}

case "$media" in
    *image.index*|*manifest.list*) ;;
    *) echo "error: debian:sid-$NEW is a single-platform manifest ($media)." >&2
       echo "       One FROM line has to serve both the amd64 and arm64 builders, so" >&2
       echo "       only a multi-architecture index can be pinned here." >&2
       exit 1 ;;
esac

# And the other half of the pin: the archive has to have a snapshot for that instant, or
# every apt-get in both images fails at build time. snapshot.debian.org answers with a 302
# to a content-addressed path, hence -L.
ts=$(timestamp_for "$NEW")
echo "debian snapshot: checking $SNAPSHOT_ARCHIVE/$ts"
code=$(curl -fsSL --retry 3 --max-time 120 -o /dev/null -w '%{http_code}' \
    "$SNAPSHOT_ARCHIVE/$ts/dists/sid/main/binary-amd64/Release") || code=000
[ "$code" = 200 ] || {
    echo "error: snapshot.debian.org has no sid archive at $ts (HTTP $code)" >&2
    exit 1
}

# Rewrite. Two lines per file, and the FROM line is written whole rather than patched,
# because the tag and the digest have to move together — a sed that replaced only the
# digest would leave the two disagreeing, which is the failure this script exists to make
# impossible.
for f in "$BUILDER" "$IMAGE"; do
    sed -i -E \
        -e "s|^ARG SNAPSHOT=[0-9]{8}|ARG SNAPSHOT=$NEW|" \
        -e "s|^FROM debian:sid-\\\$\{SNAPSHOT\}@sha256:[0-9a-f]{64}|FROM debian:sid-\${SNAPSHOT}@$digest|" \
        "$f"
done

# Read it back. sed changes nothing and says nothing when its pattern does not match, so a
# reformatted Containerfile would otherwise leave this script reporting a bump it did not
# make — the same class of quiet failure as a VERSION bumped without its SHA256.
for f in "$BUILDER" "$IMAGE"; do
    got_date=$(sed -n -E 's|^ARG SNAPSHOT=([0-9]{8}).*|\1|p' "$f" | head -n1)
    got_digest=$(sed -n -E 's|^FROM debian:sid-\$\{SNAPSHOT\}@(sha256:[0-9a-f]{64}).*|\1|p' "$f" | head -n1)
    [ "$got_date" = "$NEW" ] || { echo "error: $f still says SNAPSHOT=${got_date:-none}" >&2; exit 1; }
    [ "$got_digest" = "$digest" ] || { echo "error: $f still says ${got_digest:-no digest}" >&2; exit 1; }
done

echo "debian snapshot: $current -> $NEW"
echo "  $digest"
echo "  $BUILDER, $IMAGE"
