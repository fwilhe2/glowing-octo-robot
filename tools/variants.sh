#!/usr/bin/env bash
# What images this repository declares, for the humans and for the workflow:
#
#     ./tools/variants.sh list                # every (variant, platform) pair to build
#     ./tools/variants.sh variants            # just the variant names
#     ./tools/variants.sh platforms           # just the platform names
#     ./tools/variants.sh default             # the variant that owns the bare filenames
#     ./tools/variants.sh show net            # what net resolves to, inheritance applied
#     ./tools/variants.sh show net oci        # ...on a platform, its omissions applied
#     ./tools/variants.sh boot-matrix         # JSON for the CI boot job
#     ./tools/variants.sh publish oci         # variants that publish an oci image
#
# The host half of image/variant-lib.sh, which is also what image/build-rootfs.sh reads
# inside the assembly container. One parser rather than two: a host that thinks `net`
# builds for `oci` and a container that thinks it does not is a wrong image nobody would
# go looking for.
#
# `list` is what the rootfs CI job loops over. It is deliberately a loop inside one job
# per architecture rather than a matrix over (arch × variant): the expensive part of that
# job is downloading and extracting three dozen package artifacts, and assembling an
# image from the extracted tree is seconds. A matrix would pay the setup cost N times to
# save nothing.
set -euo pipefail

cd "$(dirname "$0")/.."

VARIANT_DIR=image/variants
PLATFORM_DIR=image/platforms
source image/variant-lib.sh

# On the host, `package *` means every package with an env.sh. Inside the assembly
# container it means every staged manifest, which is the same list minus anything that
# failed to build — see image/build-rootfs.sh for why that is the right answer there.
ALL_PACKAGES=$(for e in packages/*/env.sh; do basename "$(dirname "$e")"; done | tr '\n' ' ')

cmd="${1:-list}"

case "$cmd" in
    variants)  variant_list ;;
    platforms) platform_list ;;
    default)   default_variant; echo ;;

    list)
        for v in $(variant_list); do
            variant_load "$v"
            for p in $V_PLATFORMS; do printf '%s %s\n' "$v" "$p"; done
        done ;;

    # Which variants ask for their image of a given platform to be pushed to the
    # registry. `publish oci` in a variant file is the only thing that puts an image
    # somewhere the world can pull it from.
    publish)
        want="${2:-oci}"
        for v in $(variant_list); do
            variant_load "$v"
            if set_has "$V_PUBLISH" "$want"; then printf '%s\n' "$v"; fi
        done ;;

    tests)
        variant_load "${2:?usage: $0 tests <variant>}"
        printf '%s\n' "$V_TESTS" ;;

    show)
        variant_load "${2:?usage: $0 show <variant> [platform]}"
        printf 'variant      %s\n' "$V_NAME"
        printf 'description  %s\n' "$V_DESCRIPTION"
        printf 'platforms    %s\n' "$V_PLATFORMS"
        printf 'tests        %s\n' "$V_TESTS"
        printf 'publish      %s\n' "${V_PUBLISH:-—}"
        printf 'default      %s\n' "$V_DEFAULT"
        packages=$V_PACKAGES keep=$V_KEEP drop=$V_DROP
        if [ -n "${3:-}" ]; then
            platform_load "$3"
            packages=$(_set_del "$packages" $V_OMIT)
            keep=$(_set_add "$keep" $V_KEEP)
            drop=$(_set_add "$drop" $V_DROP)
            printf 'platform     %s (format %s)\n' "$V_NAME" "$V_FORMAT"
        fi
        printf 'packages     %s\n' "$(printf '%s\n' $packages | sort | tr '\n' ' ')"
        printf 'omitted      %s\n' "$(comm -13 <(printf '%s\n' $packages | sort -u) \
                                                <(printf '%s\n' $ALL_PACKAGES | sort -u) | tr '\n' ' ')"
        [ -z "$keep" ] || printf 'keep         %s\n' "$keep"
        [ -z "$drop" ] || printf 'drop         %s\n' "$drop" ;;

    # One JSON object per bootable image, for `strategy: matrix: include:`. Only the ext4
    # platform: booting is what a disk does, and the oci images are exercised by
    # test/oci.sh in the rootfs job, in a second, without qemu.
    #
    # `image` is the filename image/build-rootfs.sh wrote, which the default variant
    # keeps unsuffixed. `tests` is the variant's own list — a subset image that boots is
    # precisely the claim being tested, and `full` passing says nothing about `minimal`.
    boot-matrix)
        printf '['
        sep=
        for v in $(variant_list); do
            variant_load "$v"
            set_has "$V_PLATFORMS" ext4 || continue
            if [ "$V_DEFAULT" = yes ]; then image=rootfs.ext4; else image=rootfs-$v.ext4; fi
            printf '%s{"variant":"%s","image":"%s","tests":"%s"}' \
                   "$sep" "$v" "$image" "$V_TESTS"
            sep=,
        done
        printf ']\n' ;;

    *)
        echo "usage: ${0##*/} {list|variants|platforms|default|show|tests|publish|boot-matrix}" >&2
        exit 2 ;;
esac
