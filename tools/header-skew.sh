#!/bin/bash
# How far the builder's development headers are from the libraries we ship:
#
#     ./tools/header-skew.sh
#
# Every library in packages/ is compiled against twice over, in a sense: packages that
# link it compile against *Debian's* header for it (the -dev section of builder/deps.txt,
# since the CI sysroot is glibc alone), and run against *ours*, found by SONAME. That
# works while the two stay close, and docs/linking.md is the long version of why.
#
# This is the report that says how close. For each -dev package in that section: sid's
# version, ours, and which is newer. Ours newer is the safe direction — a library is
# backwards compatible with headers older than itself. sid's newer is the one to look at:
# a binary built against that header may call a function our library does not have yet.
# Whether one actually does is test/check-symbol-resolution.sh's question (and, for a
# library with versioned symbols, test/check-symbol-versions.sh's); this only says where
# to expect it. It never fails: a skew is a fact about two release schedules, not a bug.
set -euo pipefail

cd "$(dirname "$0")/.."
source tools/lib.sh

# Debian's binary package -> the package under packages/ that ships the library. Written
# out rather than derived: Debian's source names (libcap2, glib2.0, xz-utils) are not
# ours, and a lookup table nobody has to reverse-engineer is the point of the report.
declare -A ours=(
    [libacl1-dev]=acl         [libattr1-dev]=attr       [libblkid-dev]=util-linux
    [libcap-dev]=libcap       [libcrypt-dev]=libxcrypt  [libdbus-1-dev]=dbus
    [libelf-dev]=elfutils     [libexpat-dev]=expat      [libfdisk-dev]=util-linux
    [libjansson-dev]=jansson  [libglib2.0-dev]=glib     [libjson-c-dev]=json-c
    [libkmod-dev]=kmod        [liblzma-dev]=xz          [libmnl-dev]=libmnl
    [libmount-dev]=util-linux [libncurses-dev]=ncurses  [libnftnl-dev]=libnftnl
    [libpam0g-dev]=pam        [libpcre2-dev]=pcre2      [libseccomp-dev]=libseccomp
    [libssl-dev]=openssl      [libsystemd-dev]=systemd  [libzstd-dev]=zstd
    [uuid-dev]=util-linux     [zlib1g-dev]=zlib
)
# In the section, but with nothing of ours behind it: glib's build needs libffi for
# GObject, and GObject is not shipped (packages/glib/build.sh).
declare -A build_only=([libffi-dev]=1)

# The section, by its two markers: from its header to the gcc paragraph after it. If
# either moves, say so rather than report on the wrong lines.
devs=$(awk '/^# Development headers, only for libraries/ { on = 1; next }
            /^# The one exception to/ { exit }
            on && /^[a-z0-9]/ { print $1 }' builder/deps.txt)
[ -n "$devs" ] || { echo "error: no -dev section found in builder/deps.txt" >&2; exit 1; }

input=""
for dev in $devs; do
    if [ -n "${build_only[$dev]:-}" ]; then
        input+="$dev - -"$'\n'
        continue
    fi
    pkg=${ours[$dev]:-}
    if [ -z "$pkg" ]; then
        echo "error: $dev is in builder/deps.txt's -dev section but not in this script's table" >&2
        exit 1
    fi
    input+="$dev $pkg $(env_get "$pkg" VERSION)"$'\n'
done

# dpkg-query for sid's version and dpkg --compare-versions to order the two, both in the
# builder image: it is the image those headers are in, and the host may not have dpkg.
# The Debian revision and epoch are stripped first (1:2.42.4-1 is upstream 2.42.4), and
# so is a +dfsg-style repack suffix, which says nothing about the API. "+really" is how
# Debian moves a version *backwards* without breaking its own ordering — zlib's
# 1.3.dfsg+really1.3.2 is upstream 1.3.2 — so what follows it is the version. And a
# +YYYYMMDD suffix on our exact release (ncurses, libxcrypt) is sid shipping upstream's
# patches since that release: newer, but by fixes rather than by a release, so it gets
# a label of its own instead of being lumped in with a whole release ahead.
podman run --rm -i --network=none "$(./tools/image-tags.sh builder)" bash -c '
    printf "%-16s %-20s %-16s %-8s %s\n" "builder -dev" "ours" "sid" "ours is" ""
    newer=0
    while read -r dev pkg mine; do
        [ -n "$dev" ] || continue
        full=$(dpkg-query -W -f="\${Version}" "$dev" 2>/dev/null || true)
        [ -n "$full" ] || full=$(dpkg-query -W -f="\${Version}" "$(apt-cache showpkg "$dev" 2>/dev/null | awk "/^Reverse Provides:/ { getline; print \$1; exit }")" 2>/dev/null || echo "?")
        up=${full#*:}; up=${up%-*}
        case "$up" in *+really*) up=${up##*+really} ;; esac
        up=${up%%+dfsg*}; up=${up%%+ds*}
        if [ "$pkg" = - ]; then
            printf "%-16s %-20s %-16s %-8s %s\n" "$dev" "-" "$up" "-" "build only: nothing of ours behind it"
            continue
        fi
        if [ "$up" = "?" ]; then state="?"; note="not installed in the builder"
        elif dpkg --compare-versions "$mine" gt "$up"; then state="newer"; note=""
        elif dpkg --compare-versions "$mine" eq "$up"; then state="same"; note=""
        elif [ "${up%%+*}" = "$mine" ]; then state="patched"; note="sid adds upstream fixes since this release"
        else state="OLDER"; note="<- a whole release behind the sid headers"; newer=$((newer + 1))
        fi
        printf "%-16s %-20s %-16s %-8s %s\n" "$dev" "$pkg $mine" "$up" "$state" "$note"
    done
    echo
    if [ "$newer" -gt 0 ]; then
        echo "$newer header(s) newer than the library we ship. Not an error by itself:"
        echo "test/check-symbol-resolution.sh says whether any binary actually uses what is"
        echo "missing. See docs/linking.md."
    else
        echo "Every library we ship is at least as new as the header it is compiled against."
    fi
' <<< "$input"
