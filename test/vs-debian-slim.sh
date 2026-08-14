#!/usr/bin/env bash
# Our container image against the one everybody else starts from:
#
#     ./test/vs-debian-slim.sh                    # output/rootfs-size-oci.txt vs debian-slim
#     DEBIAN_SLIM=debian:forky-slim ./test/vs-debian-slim.sh
#
# test/size-budget.txt caps the image against a number somebody here wrote down, which
# answers "did it grow?" and nothing else. This asks the other question: is a
# built-from-source image still smaller than the distribution base image it would
# otherwise be replacing? That is the claim this project makes implicitly every time it
# says "minimal", and it is the one claim no ceiling in this repo can check, because the
# thing it compares against lives on a registry and moves on its own.
#
# Exceeding debian-slim is a failure. Not because a megabyte matters on its own, but
# because at that point the honest advice would be to use debian-slim: it ships a package
# manager, security updates and a decade of packaging, and this ships none of that.
#
# Both sides are measured the same way — apparent bytes of the assembled tree, the du and
# find invocations copied from image/build-rootfs.sh — so the two reports mean the same
# thing and can be subtracted. Ours is read back from the report that build wrote (the
# assembled tree only exists inside that container); the baseline is exported from the
# image and walked here.
set -euo pipefail

cd "$(dirname "$0")/.."

OURS="${1:-output/rootfs-size-oci.txt}"
BASELINE="${DEBIAN_SLIM:-debian:trixie-slim}"
THEIRS=output/rootfs-size-debian-slim.txt

# Pinned to a release rather than :stable-slim on purpose. A floating tag would move the
# comparison under a build that changed nothing, and "CI went red because Debian cut a
# release" is not a signal about this image.

ARCH="${ARCH:-$(uname -m)}"
case "$ARCH" in
    x86_64|amd64)  ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) echo "error: unsupported architecture: $ARCH (expected amd64 or arm64)" >&2; exit 1 ;;
esac

[ -f "$OURS" ] || {
    echo "error: no size report at $OURS" >&2
    echo "       image/build-rootfs.sh writes one per flavour into output/; build the OCI image first" >&2
    exit 1
}

# ---------------------------------------------------------------------------------
# The baseline, measured here. `podman export` flattens the image to a tar of its
# filesystem, which is the closest thing to the tree image/build-rootfs.sh measures — no
# layer metadata, no whiteouts, just the files. Nothing is ever run from the image, so a
# foreign architecture works on any runner.
tmp=$(mktemp -d)
cid=
cleanup() {
    [ -n "$cid" ] && podman rm -f "$cid" >/dev/null 2>&1
    rm -rf "$tmp"
}
trap cleanup EXIT

echo "measuring $BASELINE ($ARCH)..."
podman pull --quiet --arch "$ARCH" "$BASELINE" >/dev/null
cid=$(podman create --quiet --arch "$ARCH" "$BASELINE")

# --no-same-owner because this does not run as root and does not need to: every number
# below is a size, and none of them is an ownership. Debian's base image carries no
# device nodes, so an unprivileged extraction is complete rather than nearly so.
mkdir "$tmp/root"
podman export "$cid" | tar -x -C "$tmp/root" --no-same-owner

# Same three measurements as image/build-rootfs.sh, deliberately duplicated rather than
# shared: that script runs inside the image container where this one cannot reach, and a
# comparison whose two sides were counted differently would be worse than no comparison.
{
    echo "# $BASELINE ($ARCH) filesystem, sizes in bytes. Written by test/vs-debian-slim.sh."
    echo "total $(du -sb "$tmp/root" | cut -f1)"
    while read -r bytes path; do
        [ "$path" = "$tmp/root" ] && continue
        [ "$bytes" -ge 65536 ] || continue
        echo "dir $bytes ${path#"$tmp/root"/}"
    done < <(du -b --max-depth=2 "$tmp/root" | sort -rn)
    while read -r bytes path; do
        echo "file $bytes ${path#"$tmp/root"/}"
    # awk rather than `head -n 25`, which leaves sort writing to a closed pipe and saying
    # so on stderr; awk reads its input to the end and takes the first 25 lines quietly.
    done < <(find "$tmp/root" -type f -printf '%s %p\n' | sort -rn | awk 'NR<=25')
} > "$THEIRS"

# ---------------------------------------------------------------------------------
declare -A ours_dir theirs_dir
ours_total=0; theirs_total=0
ours_files=(); theirs_files=()

read_report() {  # read_report <file> <prefix>
    local kind bytes path
    while read -r kind bytes path; do
        case "$kind" in
            total) [ "$2" = ours ] && ours_total=$bytes || theirs_total=$bytes ;;
            dir)   [ "$2" = ours ] && ours_dir[$path]=$bytes || theirs_dir[$path]=$bytes ;;
            file)  [ "$2" = ours ] && ours_files+=("$bytes $path") || theirs_files+=("$bytes $path") ;;
        esac
    done < "$1"
}
read_report "$OURS" ours
read_report "$THEIRS" theirs

[ "$ours_total" -gt 0 ] && [ "$theirs_total" -gt 0 ] || {
    echo "error: one of the reports has no total" >&2; exit 1
}

mib() {  # bytes -> "12.3"
    local tenths=$(( ($1 * 10 + 524288) / 1048576 ))
    printf '%d.%d' $(( tenths / 10 )) $(( tenths % 10 ))
}

percent=$(( ours_total * 100 / theirs_total ))
delta=$(( ours_total - theirs_total ))

# The directories both images have, largest first by whichever side is bigger — this is
# the "why" half, and it reads best merged: usr/lib against usr/lib says something,
# two separate lists side by side says much less.
merged=()
for path in "${!ours_dir[@]}" "${!theirs_dir[@]}"; do
    case " ${merged[*]} " in *" $path "*) continue ;; esac
    merged+=("$path")
done
sorted=$(for path in "${merged[@]}"; do
    a=${ours_dir[$path]:-0}; b=${theirs_dir[$path]:-0}
    echo "$(( a > b ? a : b )) $a $b $path"
done | sort -rn)

summary() {
    [ -n "${GITHUB_STEP_SUMMARY:-}" ] && printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"
    return 0
}

echo
echo "container image size ($ARCH):"
printf '  %10s MiB  flfs\n'  "$(mib "$ours_total")"
printf '  %10s MiB  %s\n'    "$(mib "$theirs_total")" "$BASELINE"
if [ "$delta" -lt 0 ]; then
    echo "  → ${percent}% of debian-slim, $(mib $(( -delta ))) MiB smaller"
else
    echo "  → ${percent}% of debian-slim, $(mib "$delta") MiB LARGER"
fi

echo
echo "  where the bytes are:"
printf '    %8s  %8s  %s\n' "flfs" "debian" "directory"
while read -r _ a b path; do
    printf '    %8s  %8s  %s\n' "$(mib "$a")" "$(mib "$b")" "$path"
done <<< "$sorted"

echo
echo "  largest files, flfs:"
for entry in "${ours_files[@]:0:10}"; do
    printf '    %8s  %s\n' "$(mib "${entry%% *}")" "${entry#* }"
done
echo
echo "  largest files, $BASELINE:"
for entry in "${theirs_files[@]:0:10}"; do
    printf '    %8s  %s\n' "$(mib "${entry%% *}")" "${entry#* }"
done

summary "## Container image vs debian-slim — $ARCH"
summary ""
summary "**$(mib "$ours_total") MiB** against **$(mib "$theirs_total") MiB** for \`$BASELINE\` — ${percent}%, $(mib $(( delta < 0 ? -delta : delta ))) MiB $([ "$delta" -lt 0 ] && echo smaller || echo LARGER)."
summary ""
summary "| directory | flfs MiB | debian-slim MiB |"
summary "| --- | ---: | ---: |"
while read -r _ a b path; do
    summary "| \`$path\` | $(mib "$a") | $(mib "$b") |"
done <<< "$sorted"
summary ""
summary "<details><summary>Largest files</summary>"
summary ""
summary "| flfs | MiB |"
summary "| --- | ---: |"
for entry in "${ours_files[@]:0:10}"; do
    summary "| \`${entry#* }\` | $(mib "${entry%% *}") |"
done
summary ""
summary "| $BASELINE | MiB |"
summary "| --- | ---: |"
for entry in "${theirs_files[@]:0:10}"; do
    summary "| \`${entry#* }\` | $(mib "${entry%% *}") |"
done
summary ""
summary "</details>"

if [ "$delta" -gt 0 ]; then
    echo
    echo "error: the container image is $(mib "$delta") MiB bigger than $BASELINE on $ARCH." >&2
    echo "       The breakdown above says which directory; take it back out. There is no" >&2
    echo "       number to raise here on purpose — the point of building this from source" >&2
    echo "       is that the result is smaller than the base image it replaces, and past" >&2
    echo "       that line the honest answer is to use debian-slim, which also ships a" >&2
    echo "       package manager and security updates." >&2
    exit 1
fi
