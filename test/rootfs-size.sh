#!/usr/bin/env bash
# What an assembled image weighs, and whether that is still allowed:
#
#     ./test/rootfs-size.sh                       # the default variant's ext4 disk
#     ./test/rootfs-size.sh oci                   # ...its container image
#     ./test/rootfs-size.sh minimal ext4          # a named variant on a named platform
#     ARCH=arm64 ./test/rootfs-size.sh ext4 some/report.txt   # a report from elsewhere
#
# image/build-rootfs.sh writes the report — it is the only place the assembled tree
# exists, since rootfs/ is the input and still carries everything the trim removed. This
# reads it back, prints where the bytes are, and fails when the total is over the ceiling
# in test/size-budget.txt.
#
# The ceiling is the point. An image grows the way a garden grows over: never in one
# visible step, always a package that started installing a new data directory or a trim
# rule that quietly stopped matching. Nothing else in CI would ever fail over that, so
# the only way to notice is to have written down what the size was allowed to be, and to
# have to change that number on purpose.
set -euo pipefail

cd "$(dirname "$0")/.."

# An image is a variant on a platform. One argument naming a platform is the default
# variant on it, which is what `rootfs-size.sh ext4` and `rootfs-size.sh oci` have always
# meant and what CI and README still say.
VARIANT_DIR=image/variants
PLATFORM_DIR=image/platforms
source image/variant-lib.sh

# Positional, and disambiguated by asking whether the first word names a platform: that
# keeps `rootfs-size.sh ext4` and `rootfs-size.sh ext4 some/report.txt` meaning what they
# always meant while `rootfs-size.sh minimal ext4` means the new thing.
if [ $# -eq 0 ] || [ -f "$PLATFORM_DIR/${1:-}.conf" ]; then
    VARIANT=$(default_variant)
    PLATFORM="${1:-ext4}"
    REPORT_ARG="${2:-}"
else
    VARIANT=$1
    PLATFORM="${2:?usage: ${0##*/} [<variant>] <platform> [report]}"
    REPORT_ARG="${3:-}"
fi

[ -f "$VARIANT_DIR/$VARIANT.conf" ] || {
    echo "error: no such variant: $VARIANT (known: $(variant_list | tr '\n' ' '))" >&2
    exit 2
}
[ -f "$PLATFORM_DIR/$PLATFORM.conf" ] || {
    echo "error: no such platform: $PLATFORM (known: $(platform_list | tr '\n' ' '))" >&2
    exit 2
}

ID=$(image_id "$VARIANT" "$PLATFORM")
REPORT="${REPORT_ARG:-output/rootfs-size-$ID.txt}"
BUDGET=test/size-budget.txt

ARCH="${ARCH:-$(uname -m)}"
case "$ARCH" in
    x86_64|amd64)  ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) echo "error: unsupported architecture: $ARCH (expected amd64 or arm64)" >&2; exit 1 ;;
esac

[ -f "$REPORT" ] || {
    echo "error: no size report at $REPORT" >&2
    echo "       image/build-rootfs.sh writes one per image into output/; build it first:" >&2
    echo "           build-rootfs.sh $VARIANT $PLATFORM" >&2
    exit 1
}

# Read the report. `total` is the apparent size of the tree; the rest is what that tree
# costs in the container it ends up in, which is a different question per flavour —
# `disk`/`capacity` for what the ext4 needs once its metadata and block rounding are
# counted, `archive` for what a registry stores and a pull moves.
total=0; disk=0; capacity=0; archive=0
dirs=(); files=()
while read -r kind bytes path; do
    case "$kind" in
        '#'*|'')  continue ;;
        total)    total=$bytes ;;
        disk)     disk=$bytes ;;
        capacity) capacity=$bytes ;;
        archive)  archive=$bytes ;;
        dir)      dirs+=("$bytes $path") ;;
        file)     files+=("$bytes $path") ;;
    esac
done < "$REPORT"

[ "$total" -gt 0 ] || { echo "error: $REPORT has no total" >&2; exit 1; }

mib() {  # bytes -> "12.3"
    local tenths=$(( ($1 * 10 + 524288) / 1048576 ))
    printf '%d.%d' $(( tenths / 10 )) $(( tenths % 10 ))
}

# The budget, in MiB, keyed by variant, platform and architecture: every row is a
# different size for reasons that have nothing to do with anything going wrong (see the
# file).
budget_mib=
while read -r var plat arch mib _; do
    case "$var" in '#'*|'') continue ;; esac
    if [ "$var" = "$VARIANT" ] && [ "$plat" = "$PLATFORM" ] && [ "$arch" = "$ARCH" ]; then
        budget_mib=$mib
    fi
done < "$BUDGET"

# An image with no line here is an image nothing is watching, which is the state this
# check exists to make impossible — so it is an error rather than a pass, and the message
# is the line to add.
[ -n "$budget_mib" ] || {
    echo "error: $BUDGET has no line for $VARIANT/$PLATFORM/$ARCH, so nothing is capping it." >&2
    echo "       It measures $(mib "$total") MiB today. Add a line — the measurement plus" >&2
    echo "       about 8% of headroom, which is how the others were set:" >&2
    echo >&2
    echo "           $VARIANT    $PLATFORM    $ARCH    $(( total / 1024 / 1024 * 108 / 100 ))" >&2
    exit 1
}
budget=$(( budget_mib * 1024 * 1024 ))

# Only when running in Actions; harmless everywhere else.
summary() {
    [ -n "${GITHUB_STEP_SUMMARY:-}" ] && printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"
    return 0
}

percent=$(( total * 100 / budget ))

echo "image size ($ID, $ARCH): $(mib "$total") MiB of a $budget_mib MiB budget (${percent}%)"
[ "$disk" -gt 0 ] && echo "  on disk: $(mib "$disk") MiB written into a $(mib "$capacity") MiB filesystem"
[ "$archive" -gt 0 ] && echo "  archive: $(mib "$archive") MiB of gzipped layer, config and manifest"
echo
echo "  where it is:"
printf '    %8s  %s\n' "MiB" "directory"
for entry in "${dirs[@]}"; do
    printf '    %8s  %s\n' "$(mib "${entry%% *}")" "${entry#* }"
done
echo
echo "  largest files:"
for entry in "${files[@]}"; do
    printf '    %8s  %s\n' "$(mib "${entry%% *}")" "${entry#* }"
done

cost=
[ "$disk"    -gt 0 ] && cost="$(mib "$disk") MiB written into a $(mib "$capacity") MiB filesystem."
[ "$archive" -gt 0 ] && cost="$(mib "$archive") MiB as a gzipped OCI archive."

summary "## Image size — $ID, $ARCH"
summary ""
summary "**$(mib "$total") MiB** of a **$budget_mib MiB** budget (${percent}%). $cost"
summary ""
summary "| directory | MiB |"
summary "| --- | ---: |"
for entry in "${dirs[@]}"; do
    summary "| \`${entry#* }\` | $(mib "${entry%% *}") |"
done
summary ""
summary "<details><summary>Largest files</summary>"
summary ""
summary "| file | MiB |"
summary "| --- | ---: |"
for entry in "${files[@]}"; do
    summary "| \`${entry#* }\` | $(mib "${entry%% *}") |"
done
summary ""
summary "</details>"

if [ "$total" -gt "$budget" ]; then
    echo
    echo "error: the $ID image is $(mib "$total") MiB, over its $budget_mib MiB budget on $ARCH" >&2
    echo "       by $(mib $(( total - budget ))) MiB." >&2
    echo "       Either find what grew in the breakdown above and take it back out, or —" >&2
    echo "       if this is growth you wanted — raise the '$VARIANT $PLATFORM $ARCH' line in $BUDGET in" >&2
    echo "       the same commit that caused it. Raising it silently later is the thing this" >&2
    echo "       check exists to prevent." >&2
    exit 1
fi

# A ceiling only controls anything while it is close to the floor. Left far above the
# real size — after a large deliberate removal, say — it stops being a budget and starts
# being decoration, so say so rather than quietly passing forever.
if [ "$percent" -lt 75 ]; then
    echo
    echo "note: the image is only ${percent}% of its budget. Consider lowering the '$VARIANT"
    echo "      $PLATFORM $ARCH' line in $BUDGET to around $(( (total / 1024 / 1024) + 5 )) MiB — a ceiling"
    echo "      this far above the floor will not catch anything."
fi
