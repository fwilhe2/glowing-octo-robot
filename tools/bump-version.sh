#!/usr/bin/env bash
# Move one package to a new upstream version:
#
#     ./tools/bump-version.sh kernel 7.1.7
#
# Two lines of env.sh change, not one. PACKAGE, TARBALL and URL are all derived from
# VERSION, but SHA256 cannot be — it is a hash of bytes that exist only upstream — so it
# has to be fetched and computed. A bump that rewrites VERSION alone leaves the previous
# release's checksum sitting there, and tools/fetch-sources.sh then refuses the new
# tarball:
#
#     kernel: CHECKSUM MISMATCH from https://cdn.kernel.org/.../linux-7.1.7.tar.xz
#            expected 995dd7188d924662...   <- 7.1.6's
#            got      ca8f2a6884a4d620...
#
# which is the guard doing its job, and a build that never starts.
# .github/workflows/update-packages.yml calls this; that is the reason it is a script
# rather than two lines of sed in the workflow.
#
# What this does *not* do is check the tarball against anything upstream signed. It
# records what the canonical URL served at the moment of the bump — trust on first use.
# The pin earns its keep afterwards: mirrors, the vendored sources image and every later
# rebuild are all held to exactly those bytes. For the same reason only $URL is tried and
# never $MIRRORS — a mirror serving something else is precisely what the checksum is for,
# and pinning a mirror's bytes would enshrine the problem instead of catching it.
set -euo pipefail

cd "$(dirname "$0")/.."

PKG="${1:-}"
NEW="${2:-}"

if [ -z "$PKG" ] || [ -z "$NEW" ]; then
    echo "usage: ${0##*/} <package> <version>" >&2
    exit 2
fi

# Accept both `kernel` and the path a shell tab-completes to, `packages/kernel/`.
PKG="${PKG%/}"
PKG="${PKG#packages/}"
env_file="packages/$PKG/env.sh"

[ -f "$env_file" ] || { echo "error: unknown package '$PKG' (no $env_file)" >&2; exit 1; }

old_version=$(sed -n -E 's|^VERSION="?([^"]*)"?.*|\1|p' "$env_file" | head -n1)
old_sha=$(sed -n -E 's|^SHA256="?([^"]*)"?.*|\1|p' "$env_file" | head -n1)

sed -i -E "s|^VERSION=.*|VERSION=\"$NEW\"|" "$env_file"

# Read the file back rather than composing the URL here: every package spells its own,
# some of them out of $PKG, and this has to be the same string fetch-sources.sh will use.
#
# mapfile rather than `IFS=$'\t' read`, because a tab is IFS *whitespace*: bash collapses
# runs of it and drops leading empties, so a LOCAL_SOURCE package — which has neither a
# TARBALL nor a URL — would hand its "1" to the first variable and read as an ordinary
# package with no URL set.
mapfile -t env_values < <(
    # shellcheck disable=SC1090
    PKG="$PKG"; . "$env_file"
    printf '%s\n' "${TARBALL:-}" "${URL:-}" "${LOCAL_SOURCE:-}"
)
tarball="${env_values[0]:-}"
url="${env_values[1]:-}"
local_source="${env_values[2]:-}"

if [ -n "$local_source" ]; then
    echo "$PKG: $old_version -> $NEW (source is in this repository; no tarball, no checksum)"
    exit 0
fi

[ -n "$url" ] || { echo "error: $env_file sets no URL" >&2; exit 1; }

[ -n "$tarball" ] || { echo "error: $env_file sets no TARBALL" >&2; exit 1; }

# Into downloads/ rather than a temporary file, so the verification at the bottom costs
# nothing: fetch-sources.sh finds it already there and only hashes it. A wrong or
# half-written file left behind by a failure here is not a trap either — that is exactly
# the case fetch-sources.sh refetches.
mkdir -p downloads
echo "$PKG: fetching $url"
# Same retries as tools/fetch-sources.sh, minus its --continue-at: this deliberately
# starts from nothing, and resuming onto a previous version's leftovers is how a
# download of the wrong size gets a plausible name.
rm -f "downloads/$tarball"
curl --location --fail --silent --show-error \
     --retry 5 --retry-all-errors --retry-delay 2 \
     -o "downloads/$tarball" "$url"

new_sha=$(sha256sum <"downloads/$tarball" | cut -d' ' -f1)

if grep -q '^SHA256=' "$env_file"; then
    sed -i -E "s|^SHA256=.*|SHA256=\"$new_sha\"|" "$env_file"
else
    # Keep it with the three lines it belongs beside rather than at the end of the file.
    sed -i -E "/^URL=/a SHA256=\"$new_sha\"" "$env_file"
fi

echo "$PKG: $old_version -> $NEW"
echo "  $tarball"
echo "  sha256 ${old_sha:-(none)} -> $new_sha"

# Free, now that the tarball is already in downloads/, and worth doing: it proves the
# file that was just written describes the bytes it names, read back through the same
# code that will reject it in CI if it does not.
if ! ./tools/fetch-sources.sh "$PKG" >/dev/null; then
    echo "error: $PKG does not verify after the bump" >&2
    exit 1
fi
