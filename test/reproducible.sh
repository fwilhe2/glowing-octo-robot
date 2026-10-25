#!/usr/bin/env bash
# Build packages twice, each time from nothing, and fail unless the two results are
# byte-identical:
#
#     ./test/reproducible.sh bash openssh kernel
#     KEEP=1 ./test/reproducible.sh curl      # leave both trees behind to diff by hand
#     AGAINST_RUN=<run-id> ./test/reproducible.sh bash   # build once, compare with CI's
#
# AGAINST_RUN is the stronger of the two: instead of a second local build, the reference
# is the package-<pkg>-<arch> artifact that CI run built on a GitHub runner — another
# machine, kernel, CPU and user — and the local build compiles against that run's own
# glibc artifact, the glibc-only sysroot CI's build matrix uses. HEAD has to be the commit
# the run built. Needs gh.
#
# "From nothing" is the point. Each build gets its own git worktree of HEAD — so a fresh
# extraction of the tarball and an empty rootfs/ for DESTDIR — because a second build in
# the same source tree is mostly `make` deciding there is nothing to do, and would agree
# with the first for the wrong reason. Committed state only, for the same reason: the
# worktree is HEAD, not whatever is uncommitted here.
#
# What is compared is what the image is made from: every staged file's contents, mode and
# owner, and every symlink's target. Not mtimes — image/build-rootfs.sh clamps all of them
# to SOURCE_DATE_EPOCH, so a staged file's own timestamp never reaches an image, and
# including it would fail every package for a difference nothing ships.
#
# Packages compile against SYSROOT_DIR (default sysroot/, the glibc-only tree
# ./build.sh glibc fills), read-only, exactly as CI's build matrix does against its own.
# Both builds see the same one, so it cannot be the difference — and it has to be
# glibc-only for AGAINST_RUN to mean anything, since CI's has nothing else in it.
set -euo pipefail

cd "$(dirname "$0")/.."
source tools/lib.sh

[ $# -gt 0 ] || { echo "usage: ${0##*/} <package>..." >&2; exit 2; }

work="$PWD/output/reproducible"
mkdir -p "$work"
arch=$(normalize_arch "${ARCH:-}")

if [ -n "${AGAINST_RUN:-}" ]; then
    run_sha=$(gh run view "$AGAINST_RUN" --json headSha -q .headSha)
    [ "$run_sha" = "$(git rev-parse HEAD)" ] || {
        echo "error: run $AGAINST_RUN built ${run_sha:0:7}, but HEAD is $(git rev-parse --short HEAD)" >&2
        exit 1
    }
fi

# A CI package artifact, unpacked: <pkg>.tar holding rootfs/..., as
# .github/actions/build-package writes it. Unpacked as ourselves, so its files are owned
# by the same uid the container's root maps to here, which is what the runner's were.
ci_tree() { # pkg dest
    rm -rf "$2.dl" "$2" && mkdir -p "$2"
    gh run download "$AGAINST_RUN" -n "package-$1-$arch" -D "$2.dl" >/dev/null
    tar xpf "$2.dl/$1.tar" -C "$2" --strip-components=1
    rm -rf "$2.dl"
}

if [ -n "${AGAINST_RUN:-}" ]; then
    ci_tree glibc "$work/ci-sysroot"
    sysroot="$work/ci-sysroot"
else
    sysroot=$(realpath "${SYSROOT_DIR:-sysroot}")
fi

# Staged files belong to the build container's root, which is a subuid out here, so
# reading and deleting them goes through the same user namespace that wrote them.
in_ns() { podman unshare "$@"; }

cleanup_tree() {
    local wt=$1
    [ -d "$wt" ] || return 0
    in_ns rm -rf "$wt/rootfs" "$wt/packages" 2>/dev/null || true
    git worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
}

# One line per staged path: type, mode, owner, symlink target or content hash.
manifest() {
    in_ns bash -c 'cd "$1" && find . -mindepth 1 -printf "%y %m %U:%G %p\n" | sort -k4 |
        while read -r type mode owner path; do
            case "$type" in
                f) echo "$type $mode $owner $path $(sha256sum < "$path" | cut -c1-64)" ;;
                l) echo "$type $mode $owner $path -> $(readlink "$path")" ;;
                *) echo "$type $mode $owner $path" ;;
            esac
        done' _ "$1"
}

failed=()
for pkg in "$@"; do
    pkg=$(package_name "$pkg")
    runs="1 2"
    if [ -n "${AGAINST_RUN:-}" ]; then
        runs=1
        ci_tree "$pkg" "$work/$pkg-ci"
        manifest "$work/$pkg-ci" > "$work/$pkg-2.manifest"
        rm -rf "$work/$pkg-ci"
    fi
    for run in $runs; do
        wt="$work/$pkg-$run"
        cleanup_tree "$wt"
        git worktree add --quiet --detach "$wt" HEAD
        # The tarballs are inputs, verified against their pins by prep either way, so the
        # two builds can share this checkout's rather than each unpacking every source.
        mkdir -p downloads
        ln -s "$PWD/downloads" "$wt/downloads"
        echo ">> $pkg: build $run of $(echo $runs | wc -w)"
        if ! (cd "$wt" && SYSROOT_DIR="$sysroot" ./build.sh "$pkg") \
                > "$work/$pkg-$run.log" 2>&1; then
            echo ">> $pkg: build $run FAILED, see $work/$pkg-$run.log" >&2
            failed+=("$pkg")
            continue 2
        fi
        manifest "$wt/rootfs" > "$work/$pkg-$run.manifest"
    done

    if cmp -s "$work/$pkg-1.manifest" "$work/$pkg-2.manifest"; then
        echo ">> $pkg: reproducible ($(wc -l < "$work/$pkg-1.manifest") paths${AGAINST_RUN:+, identical to CI run $AGAINST_RUN})"
    else
        echo ">> $pkg: NOT reproducible; differing paths:" >&2
        diff "$work/$pkg-1.manifest" "$work/$pkg-2.manifest" | sed -n 's/^[<>] //p' |
            awk '{ print "     " $4 }' | sort -u | head -40 >&2
        failed+=("$pkg")
    fi

    if [ -z "${KEEP:-}" ]; then
        cleanup_tree "$work/$pkg-1"
        cleanup_tree "$work/$pkg-2"
    fi
done
git worktree prune
rm -rf "$work/ci-sysroot"

if [ ${#failed[@]} -gt 0 ]; then
    echo ">> not reproducible: ${failed[*]}" >&2
    exit 1
fi
echo ">> all reproducible: $*"
