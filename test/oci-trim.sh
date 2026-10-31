#!/usr/bin/env bash
# What the container flavour leaves out of the disk image, and whether what is left still
# links — the OCI subtractions in image/build-rootfs.sh, made reviewable:
#
#     ./test/oci-trim.sh [output-dir]          # a summary by area
#     FULL=1 ./test/oci-trim.sh [output-dir]   # every path
#
# Nothing here re-derives the subtractions. It compares the manifests the assembly writes
# of each finished tree (rootfs-files-erofs.txt, rootfs-files-oci.txt) and so shows the
# whole difference, the trim's side effects included:
#
#   removed   paths in the disk image and not in the container, by area (the first three
#             path components), with the shared libraries among them named
#   added     paths only the container has (its /home/user, the /var the disk image
#             empties for its tmpfs)
#   links     test/check-rootfs-deps.sh run on the container's own layer, unpacked from
#             flfs-oci.tar: the evidence that no binary left behind needs a library the
#             subtractions deleted. build-rootfs.sh's own consumer guards (glib and pcre2,
#             libudev) fail the assembly before this; this covers everything else.
#
# Fails only when the links check does, or an input is missing. CI runs it in the rootfs
# job and puts it in the job summary.
set -euo pipefail

cd "$(dirname "$0")/.."
export LC_ALL=C

out=${1:-output}
erofs=$out/rootfs-files-erofs.txt oci=$out/rootfs-files-oci.txt archive=$out/flfs-oci.tar
for f in "$erofs" "$oci" "$archive"; do
    [ -f "$f" ] || { echo "error: no $f (./tools/build-image.sh writes it)" >&2; exit 1; }
done

work=$(mktemp -d)
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT

grep -v '^#' "$erofs" | sort > "$work/erofs"
grep -v '^#' "$oci" | sort > "$work/oci"
comm -23 "$work/erofs" "$work/oci" > "$work/removed"
comm -13 "$work/erofs" "$work/oci" > "$work/added"

# A removed directory's contents are removed too; only the topmost path of each removed
# subtree is counted as an entry, so `usr/lib/systemd` is one line, not four hundred.
awk 'NR == 1 || index($0, prev "/") != 1 { print; prev = $0 }' "$work/removed" > "$work/removed-tops"

size() { sed -n 's/^total //p' "$out/rootfs-size-$1.txt" 2>/dev/null; }

echo "OCI image against the disk image ($(wc -l < "$work/erofs") and $(wc -l < "$work/oci") paths)"
if [ -n "$(size erofs)" ] && [ -n "$(size oci)" ]; then
    source tools/lib.sh
    echo "  tree size: $(mib "$(size erofs)") MiB disk, $(mib "$(size oci)") MiB container"
fi
echo "  removed:   $(wc -l < "$work/removed") paths, in $(wc -l < "$work/removed-tops") subtrees or files"
echo "  added:     $(wc -l < "$work/added") paths"
echo

echo "removed, by area (paths):"
awk -F/ '{ a = $1; if (NF > 1) a = a "/" $2; if (NF > 2) a = a "/" $3; n[a]++ }
         END { for (a in n) printf "%6d  %s\n", n[a], a }' "$work/removed" | sort -k1,1nr -k2 | head -n 25

echo
echo "shared libraries removed:"
grep -E '(^|/)lib[^/]*\.so(\.[0-9.]+)?$' "$work/removed" | sed 's/^/  /' || echo "  (none)"

echo
echo "added (only in the container):"
awk 'NR == 1 || index($0, prev "/") != 1 { print; prev = $0 }' "$work/added" | sed 's/^/  /'
[ -s "$work/added" ] || echo "  (none)"

if [ "${FULL:-0}" = 1 ]; then
    echo
    echo "every removed path:"
    sed 's/^/  /' "$work/removed"
fi

# The container's own tree, from its one layer: index.json -> manifest -> layer.
mkdir "$work/oci-layout" "$work/tree"
tar xf "$archive" -C "$work/oci-layout"
manifest=$(sed -n 's/.*"digest": *"sha256:\([0-9a-f]*\)".*/\1/p' "$work/oci-layout/index.json" | head -n1)
layer=$(tr -d '\n ' < "$work/oci-layout/blobs/sha256/$manifest" |
    sed 's/.*"layers":\[{[^}]*"digest":"sha256:\([0-9a-f]*\)".*/\1/')
[ -f "$work/oci-layout/blobs/sha256/$layer" ] || { echo "error: no layer blob in $archive" >&2; exit 1; }
tar xzf "$work/oci-layout/blobs/sha256/$layer" -C "$work/tree" --no-same-owner --no-same-permissions \
    --exclude='./dev/*'

echo
echo "links: test/check-rootfs-deps.sh on the container's layer"
if ./test/check-rootfs-deps.sh "$work/tree" > "$work/deps" 2>&1; then
    tail -n1 "$work/deps" | sed 's/^/  /'
else
    sed 's/^/  /' "$work/deps"
    echo "error: a binary in the container needs a library it does not ship; see above" >&2
    exit 1
fi
