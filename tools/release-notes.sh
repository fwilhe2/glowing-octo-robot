#!/bin/bash
# Print a best-effort release-notes URL for a package and version.
#
# GitHub releases are preferred where packages/<pkg>/env.sh declares UPSTREAM_GITHUB.
# The kernel has no GitHub release stream, so its canonical kernel.org ChangeLog is used.
# Missing notes are normal and intentionally produce a non-zero exit with no output.
set -euo pipefail

cd "$(dirname "$0")/.."

PKG="${1:-}"
TARGET_VERSION="${2:-}"
if [ -z "$PKG" ] || [ -z "$TARGET_VERSION" ] || [ ! -f "packages/$PKG/env.sh" ]; then
    exit 1
fi

source "packages/$PKG/env.sh"

fetch() {
    curl -fsSL --max-time 60 --retry 2 --retry-delay 2 "$@"
}

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

if [ "$PKG" = kernel ]; then
    printf 'https://cdn.kernel.org/pub/linux/kernel/v%s.x/ChangeLog-%s\n' \
        "${TARGET_VERSION%%.*}" "$TARGET_VERSION"
    exit 0
fi

UPSTREAM_GITHUB="${UPSTREAM_GITHUB:-}"
if [ -z "$UPSTREAM_GITHUB" ]; then
    exit 1
fi

UPSTREAM_SED="${UPSTREAM_SED:-}"
while IFS=$'\t' read -r tag url; do
    [ -n "$tag" ] || continue
    normalized=${tag#v}
    if [ -n "$UPSTREAM_SED" ]; then
        normalized=$(printf '%s\n' "$normalized" | sed -E "$UPSTREAM_SED")
    fi
    if [ "$normalized" = "$TARGET_VERSION" ]; then
        printf '%s\n' "$url"
        exit 0
    fi
done < <(gh_api "https://api.github.com/repos/$UPSTREAM_GITHUB/releases?per_page=100" \
    | jq -r '.[] | select((.draft or .prerelease) | not) | [.tag_name, .html_url] | @tsv')

exit 1
