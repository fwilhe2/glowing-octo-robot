#!/bin/bash
# Print the latest version a package's upstream has released:
#
#     lib/upstream.sh coreutils
#     9.8
#
# Where to look is declared in the package's env.sh. Nothing is needed for the common
# case — a mirror directory holding every release side by side — because that is the
# directory $URL already points into. The knobs, all optional:
#
#   UPSTREAM_GITHUB   owner/repo. Take versions from the repo's GitHub releases,
#                     falling back to its tags. For projects whose downloads live on
#                     GitHub, where there is no listing to scrape.
#   UPSTREAM_INDEX    URL of an HTML directory listing to scrape. Defaults to the
#                     directory $URL lives in.
#   UPSTREAM_SUBDIR   ERE matching per-release subdirectories of UPSTREAM_INDEX. When
#                     set, the newest matching subdirectory is scraped instead of the
#                     index itself — kernel.org files util-linux tarballs one level
#                     down, in v2.41/.
#   UPSTREAM_REGEX    ERE matching release file names, with the version in group 1.
#                     Defaults to $TARBALL with the version replaced by a number
#                     pattern, e.g. coreutils-([0-9]+(\.[0-9]+)*)\.tar\.gz.
#   UPSTREAM_SED      sed -E expression applied to every candidate before it is judged,
#                     for upstreams whose releases aren't named after the version —
#                     expat tags 2.8.2 as R_2_8_2.
#   UPSTREAM_IGNORE   ERE of versions to skip.
#
# Only plain numeric versions are ever considered, so alphas, betas and release
# candidates never show up as an update.
set -euo pipefail

NUM='[0-9]+(\.[0-9]+)*'

fetch() {
    curl -fsSL --max-time 60 --retry 2 --retry-delay 2 "$@"
}

# GitHub's API allows 60 unauthenticated requests an hour, which a couple of full runs
# exhaust; the workflow passes GH_TOKEN, and locally gh's own token does the job.
gh_api() {
    local token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
    if [ -z "$token" ] && command -v gh >/dev/null; then
        token=$(gh auth token 2>/dev/null || true)
    fi
    if [ -n "$token" ]; then
        fetch -H "Authorization: Bearer $token" -H 'Accept: application/vnd.github+json' "$1"
    else
        fetch -H 'Accept: application/vnd.github+json' "$1"
    fi
}

# Tags and releases both, because neither is complete on its own: kmod tags every
# release but only writes release notes for some (its newest GitHub release is v34
# while v34.2 is out), and a repo with thousands of tags could push the newest ones
# off the first page of the tags API.
github_versions() {
    local repo="$1"
    {
        gh_api "https://api.github.com/repos/$repo/tags?per_page=100" | jq -r '.[].name'
        gh_api "https://api.github.com/repos/$repo/releases?per_page=100" \
            | jq -r '.[] | select((.draft or .prerelease) | not) | .tag_name'
    } | sed 's/^v//'
}

index_versions() {
    local url="$1" regex="$2" page
    # Fetch first, so an unreachable listing fails loudly while a listing that simply
    # holds nothing matching falls through to the "found no versions" error below.
    page=$(fetch "$url")
    # grep -o yields whole matches (acl-2.4.0.tar.gz); sed then pulls out group 1.
    printf '%s\n' "$page" | grep -oE "$regex" | sed -E "s#^$regex\$#\1#" || true
}

# Turn a concrete tarball name into a regex matching any version of it: mark where
# this package's version sits, escape the regex metacharacters in what's left, then
# put a number pattern where the mark was.
default_regex() {
    local tarball="$1" version="$2" marked escaped
    marked="${tarball/$version/@@V@@}"
    escaped=$(printf '%s' "$marked" | sed -E 's/[][^$.*+?(){}|\\]/\\&/g')
    printf '%s' "${escaped/@@V@@/($NUM)}"
}

PKG="${1:-}"
if [ -z "$PKG" ]; then
    echo "usage: $0 <package>" >&2
    exit 1
fi

PKG="${PKG%/}"
if [ ! -f "$PKG/env.sh" ]; then
    echo "error: unknown package '$PKG' (no $PKG/env.sh)" >&2
    exit 1
fi

source "$PKG/env.sh"

UPSTREAM_GITHUB="${UPSTREAM_GITHUB:-}"
UPSTREAM_SUBDIR="${UPSTREAM_SUBDIR:-}"
UPSTREAM_SED="${UPSTREAM_SED:-}"
UPSTREAM_IGNORE="${UPSTREAM_IGNORE:-}"
UPSTREAM_REGEX="${UPSTREAM_REGEX:-$(default_regex "$TARBALL" "$VERSION")}"

if [ -n "$UPSTREAM_GITHUB" ]; then
    candidates=$(github_versions "$UPSTREAM_GITHUB")
else
    index="${UPSTREAM_INDEX:-${URL%/*}/}"
    if [ -n "$UPSTREAM_SUBDIR" ]; then
        dirs=$(fetch "$index" | { grep -oE "$UPSTREAM_SUBDIR" || true; } | sort -Vu | tac)
        if [ -z "$dirs" ]; then
            echo "error: $PKG: no subdirectory matching '$UPSTREAM_SUBDIR' at $index" >&2
            exit 1
        fi
        # Newest first, stopping at the first directory that actually holds a release:
        # the directory for a new series appears before its first final release, so the
        # newest one can contain nothing but release candidates for a while.
        candidates=""
        while IFS= read -r dir; do
            candidates=$(index_versions "${index%/}/$dir" "$UPSTREAM_REGEX")
            if [ -n "$candidates" ]; then break; fi
        done <<< "$dirs"
    else
        candidates=$(index_versions "$index" "$UPSTREAM_REGEX")
    fi
fi

if [ -n "$UPSTREAM_SED" ]; then
    candidates=$(printf '%s\n' "$candidates" | sed -E "$UPSTREAM_SED")
fi

# Keep only plain numeric versions, so 6.6-rc1 and 20250101 snapshots stay out.
numeric=$(printf '%s\n' "$candidates" | grep -E "^$NUM\$" || true)
if [ -n "$UPSTREAM_IGNORE" ]; then
    numeric=$(printf '%s\n' "$numeric" | grep -Ev "^$UPSTREAM_IGNORE\$" || true)
fi

latest=$(printf '%s\n' "$numeric" | sort -Vu | tail -1)

if [ -z "$latest" ]; then
    echo "error: $PKG: found no versions upstream" >&2
    exit 1
fi

printf '%s\n' "$latest"
