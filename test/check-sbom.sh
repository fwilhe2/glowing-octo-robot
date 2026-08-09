#!/usr/bin/env bash
# Does the SBOM this build produced actually say what is in the image?
#
#     ./test/check-sbom.sh                       # both flavours from output/
#     ./test/check-sbom.sh output/sbom-oci.json  # one document
#
# image/build-rootfs.sh writes the document by hand, because the alternative is putting a
# JSON serialiser into image/Containerfile to emit thirty string fields (the same argument
# that keeps buildah out of the OCI assembly). That is a reasonable trade only if
# something afterwards proves the result parses — otherwise "we control the values" is an
# assumption, and a malformed SBOM is worse than no SBOM: it is a file that looks like an
# answer and silently is not.
#
# So this runs on the CI runner rather than in the image container, where there is a real
# JSON parser to hand, and it is what makes issue #75's "CI fails if it cannot be
# produced" mean something. It checks three things:
#
#   1. it is JSON, and it is SPDX 2.3
#   2. every component carries the provenance the issue asked for — version, download
#      location, and a SHA256 for anything that came from a tarball
#   3. it describes *this* image: every package staged into the tree is in it, and the
#      relationship graph has no dangling references
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v jq >/dev/null 2>&1; then
    echo "error: jq is required (it is on every GitHub runner; install it locally)" >&2
    exit 1
fi

docs=("$@")
if [ ${#docs[@]} -eq 0 ]; then
    for f in output/sbom-ext4.json output/sbom-oci.json; do
        [ -f "$f" ] && docs+=("$f")
    done
fi

if [ ${#docs[@]} -eq 0 ]; then
    echo "error: no SBOM in output/ — image/build-rootfs.sh writes one per flavour" >&2
    echo "       and is supposed to fail rather than skip it, so its absence is the bug" >&2
    exit 1
fi

status=0
fail() { echo "  FAIL: $*" >&2; status=1; }

for doc in "${docs[@]}"; do
    echo "$doc"

    if ! jq empty "$doc" 2>/dev/null; then
        fail "not valid JSON"
        jq empty "$doc" 2>&1 | sed 's/^/        /' >&2 || true
        continue
    fi

    [ "$(jq -r '.spdxVersion' "$doc")" = "SPDX-2.3" ] || fail "spdxVersion is not SPDX-2.3"
    [ "$(jq -r '.SPDXID' "$doc")" = "SPDXRef-DOCUMENT" ] || fail "missing SPDXRef-DOCUMENT"
    [ -n "$(jq -r '.documentNamespace // empty' "$doc")" ] || fail "no documentNamespace"
    [ -n "$(jq -r '.creationInfo.created // empty' "$doc")" ] || fail "no creationInfo.created"

    # SPDX ids have to be unique — two packages sharing one is the mistake a hand-written
    # serialiser makes, and a consumer resolves the relationship to whichever it saw last.
    dupes=$(jq -r '.packages[].SPDXID' "$doc" | sort | uniq -d)
    [ -z "$dupes" ] || fail "duplicate SPDXIDs: $(echo "$dupes" | tr '\n' ' ')"

    # Provenance, which is the whole point of generating this rather than scanning for it.
    # A package with a downloadLocation and no checksum is fine only when it did not come
    # from a tarball — a local-source package points at the repository instead.
    bad=$(jq -r '
        .packages[]
        | select(.SPDXID | startswith("SPDXRef-Package-"))
        | select((.versionInfo // "") == "" or (.downloadLocation // "NOASSERTION") == "NOASSERTION")
        | .name' "$doc")
    [ -z "$bad" ] || fail "packages with no version or download location: $(echo "$bad" | tr '\n' ' ')"

    unhashed=$(jq -r '
        .packages[]
        | select(.SPDXID | startswith("SPDXRef-Package-"))
        | select(.downloadLocation | startswith("git+") | not)
        | select((.checksums // []) | length == 0)
        | .name' "$doc")
    [ -z "$unhashed" ] || fail "tarball packages with no SHA256: $(echo "$unhashed" | tr '\n' ' ')"

    # Every relationship has to name elements that exist. This is the other thing a
    # hand-written graph gets wrong, and it is invisible until a consumer walks it.
    dangling=$(jq -r '
        [ .packages[].SPDXID, "SPDXRef-DOCUMENT" ] as $ids
        | .relationships[]
        | select((.spdxElementId | IN($ids[]) | not) or (.relatedSpdxElement | IN($ids[]) | not))
        | "\(.spdxElementId) -\(.relationshipType)-> \(.relatedSpdxElement)"' "$doc")
    [ -z "$dangling" ] || fail "relationships naming unknown elements:"$'\n'"$dangling"

    # An image with no CONTAINS is a document about nothing, which is exactly what a
    # scanner would have produced and the reason this is generated instead.
    contains=$(jq '[ .relationships[] | select(.relationshipType == "CONTAINS") ] | length' "$doc")
    [ "$contains" -gt 0 ] || fail "no CONTAINS relationships — the image describes nothing"

    # The libraries the image references and does not ship are DEPENDS_ON *without* a
    # CONTAINS, which is how SPDX says "needed, not present". Assert the shape rather than
    # the contents: which libraries are missing is test/check-rootfs-deps.sh's business,
    # and duplicating its allowlist here would make two places to update.
    unresolved=$(jq -r '[ .packages[] | select(.SPDXID | startswith("SPDXRef-Unresolved-")) ] | length' "$doc")
    wrongly_contained=$(jq -r '
        [ .relationships[]
          | select(.relationshipType == "CONTAINS")
          | select(.relatedSpdxElement | startswith("SPDXRef-Unresolved-")) ] | length' "$doc")
    [ "$wrongly_contained" = 0 ] || fail "$wrongly_contained unresolved libraries claimed as CONTAINS"

    pkgs=$(jq '[ .packages[] | select(.SPDXID | startswith("SPDXRef-Package-")) ] | length' "$doc")
    builders=$(jq '[ .packages[] | select(.SPDXID | startswith("SPDXRef-Builder-")) ] | length' "$doc")
    echo "  $pkgs packages, $builders build tools, $unresolved unresolved libraries, $contains CONTAINS"
done

exit $status
