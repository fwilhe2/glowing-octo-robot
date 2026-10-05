#!/usr/bin/env bash
# Accept the kernel config a build resolved, as packages/kernel/config-<arch>.lock:
#
#     ./tools/kernel-config-lock.sh            # from the local kernel tree, this host's arch
#     ./tools/kernel-config-lock.sh <run-id>   # from a CI run, every arch it proposed
#
# packages/kernel/build.sh compares the config it resolved against the lock and stops
# before compiling when they differ, leaving the resolved one beside the source as
# config-<arch>.lock.new. Locally that is in packages/kernel/linux-<version>/; in CI the
# kernel job uploads it as the proposed-kernel-<arch> artifact. This copies it into place
# and prints what changed — which is the part to read before committing.
#
# The arm64 lock can only come from CI unless you have an arm64 machine: kconfig asks the
# compiler what it supports, and the builder's compiler only targets its own arch.
set -euo pipefail

cd "$(dirname "$0")/.."
source tools/lib.sh

load_env kernel

accept() {  # accept <proposed lock file> <arch>
    local new="$1" arch="$2" lock="packages/kernel/config-$2.lock"
    local added removed
    if [ -f "$lock" ]; then
        added=$(diff <(grep -v '^#' "$lock") <(grep -v '^#' "$new") | grep -c '^>' || true)
        removed=$(diff <(grep -v '^#' "$lock") <(grep -v '^#' "$new") | grep -c '^<' || true)
        echo "$arch: +$added -$removed"
        diff <(grep -v '^#' "$lock") <(grep -v '^#' "$new") | grep '^[<>]' \
            | sed -e 's/^</  -/' -e 's/^>/  +/' || true
    else
        echo "$arch: new lock, $(grep -vc '^#' "$new") symbols"
    fi
    cp "$new" "$lock"
}

if [ $# -eq 0 ]; then
    arch=$(normalize_arch)
    new="packages/kernel/$PACKAGE/config-$arch.lock.new"
    if [ ! -f "$new" ]; then
        echo "error: no $new — run ./build.sh kernel first" >&2
        exit 1
    fi
    accept "$new" "$arch"
else
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    gh run download "$1" --pattern 'proposed-kernel-*' --dir "$tmp"
    found=
    # Searched for rather than globbed: upload-artifact keeps the path below the wildcard,
    # so the file arrives as proposed-kernel-<arch>/linux-<version>/config-<arch>.lock.new.
    while IFS= read -r -d '' new; do
        arch="${new##*/config-}"
        accept "$new" "${arch%.lock.new}"
        found=1
    done < <(find "$tmp" -name 'config-*.lock.new' -print0 | sort -z)
    if [ -z "$found" ]; then
        echo "error: run $1 proposed no kernel config lock" >&2
        exit 1
    fi
fi

echo
echo "Review the lines above, then commit packages/kernel/config-*.lock."
