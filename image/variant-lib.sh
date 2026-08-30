#!/usr/bin/env bash
# The reader for image/variants/*.conf and image/platforms/*.conf.
#
# Sourced, never executed, and deliberately by two callers on opposite sides of a
# container boundary: image/build-rootfs.sh, which assembles an image, and
# tools/variants.sh, which enumerates the (variant, platform) pairs CI has to build and
# boot. One parser rather than two, because a host that thinks `net` builds for `oci` and
# a container that thinks it does not is a wrong image nobody would look for.
#
# The files are line-oriented text with `#` comments — the idiom of builder/deps.txt and
# test/size-budget.txt — rather than sourced shell. Three reasons, all of them about the
# two callers above: it has to be read from a container and from the host, it should be
# diffable in a pull request without tracing control flow, and a directive that cannot be
# executed cannot do anything surprising.
#
# The caller sets:
#
#   VARIANT_DIR    where the variants live   (image/variants, or /variants in the image
#                                             assembly container)
#   PLATFORM_DIR   where the platforms live
#   ALL_PACKAGES   what `package *` means. On the host that is every packages/*/env.sh;
#                  inside the assembly container it is every staged manifest, which is
#                  the same list minus anything that failed to build — and the assembled
#                  tree is what an image is selected from, so that is the right answer
#                  there.
#
# ...and then calls variant_load / platform_load, which set the V_* / P_* variables
# below. Both are plain globals: this is bash, the alternative is namerefs, and there is
# exactly one variant and one platform in flight at a time.

# ---------------------------------------------------------------------------------
# Sets, as space-separated strings. Small enough (three dozen package names) that the
# readability is worth more than the O(n²).
_set_add() {  # <set> <item…> -> the set with each item appended if it is not already in it
    local out=" $1 " item
    shift
    for item in "$@"; do
        case "$out" in *" $item "*) ;; *) out="$out$item " ;; esac
    done
    # Unquoted, so the shell collapses the padding this built up.
    echo $out
}

_set_del() {  # <set> <item…> -> the set with each item removed
    local out=" $1 " item
    shift
    for item in "$@"; do out=${out//" $item "/" "}; done
    echo $out
}

set_has() {  # <set> <item>
    case " $1 " in *" $2 "*) return 0 ;; esac
    return 1
}

# ---------------------------------------------------------------------------------
# One line at a time. `read -r key rest` splits on the first run of whitespace, which is
# what makes `description  a sentence with spaces` and `package  a b c` both work with no
# quoting anywhere in the file.
#
# The directives are applied in file order, and a file's `extends` parent is applied in
# full before any of its own lines — see the resolution order in docs/image-variants.md,
# which this function is the implementation of.
#
# Globbing is off for the whole pass, and that is load-bearing rather than tidy: half the
# directives here take patterns — `package *`, `keep usr/lib/libsystemd.so.0*` — and every
# one of them is a word this parser has to leave alone. Unquoted in a shell with pathname
# expansion on, `*` becomes the contents of whatever directory the caller happened to be
# standing in, which for build-rootfs.sh is the image tree itself.
_conf_apply() {
    local rc=0 noglob=off
    case "$-" in *f*) noglob=on ;; esac
    set -f
    _conf_apply_lines "$@" || rc=$?
    [ "$noglob" = on ] || set +f
    return $rc
}

_conf_apply_lines() {  # <file> <what: variant|platform>
    local file=$1 what=$2 key rest word

    [ -f "$file" ] || { echo "error: no such $what file: $file" >&2; return 1; }

    while read -r key rest; do
        # Trailing comments are not stripped: a `#` inside a glob would be a legal
        # pattern character, and a rule that sometimes eats half a directive is worse
        # than one that never does. Comments go on their own line.
        case "$key" in ''|'#'*) continue ;; esac

        case "$key" in
            description) V_DESCRIPTION=$rest ;;
            extends)
                [ "$what" = variant ] || { echo "error: $file: 'extends' is a variant directive" >&2; return 1; }
                # Already resolved by variant_load before this pass; see there.
                ;;
            format)
                [ "$what" = platform ] || { echo "error: $file: 'format' is a platform directive" >&2; return 1; }
                V_FORMAT=$rest ;;
            platforms)   V_PLATFORMS=$(_set_add "$V_PLATFORMS" $rest) ;;
            tests)       V_TESTS=$(_set_add "$V_TESTS" $rest) ;;
            publish)     V_PUBLISH=$(_set_add "$V_PUBLISH" $rest) ;;
            files)       V_FILES=$rest ;;
            default)     case "$rest" in yes|true|1) V_DEFAULT=yes ;; *) V_DEFAULT=no ;; esac ;;
            package)
                # `*` is every package there is, which is what `full` means and the one
                # place a variant is allowed not to name its contents.
                for word in $rest; do
                    if [ "$word" = '*' ]; then
                        V_PACKAGES=$(_set_add "$V_PACKAGES" $ALL_PACKAGES)
                    else
                        V_PACKAGES=$(_set_add "$V_PACKAGES" "$word")
                    fi
                done ;;
            omit)        V_PACKAGES=$(_set_del "$V_PACKAGES" $rest)
                         V_OMIT=$(_set_add "$V_OMIT" $rest) ;;
            keep)        V_KEEP=$(_set_add "$V_KEEP" $rest) ;;
            drop)        V_DROP=$(_set_add "$V_DROP" $rest) ;;
            *)
                echo "error: $file: unknown directive '$key'" >&2
                echo "       known: description extends format platforms package omit keep drop" >&2
                echo "              files tests publish default" >&2
                return 1 ;;
        esac
    done < "$file"
}

# The parent chain, oldest first. Single inheritance, and the cycle guard is a depth
# counter rather than a seen-list because the only way to exceed it is a cycle: nobody
# is going to write sixteen levels of variant.
_variant_chain() {  # <name> -> prints the chain, oldest first
    local name=$1 depth=${2:-0} parent
    [ "$depth" -lt 16 ] || { echo "error: 'extends' loops at $name" >&2; return 1; }
    parent=$(awk '$1 == "extends" { print $2; exit }' "$VARIANT_DIR/$name.conf" 2>/dev/null || true)
    if [ -n "$parent" ]; then
        _variant_chain "$parent" $(( depth + 1 )) || return 1
    fi
    printf '%s\n' "$name"
}

variant_load() {  # <name>
    V_NAME=$1
    V_DESCRIPTION= V_PACKAGES= V_OMIT= V_KEEP= V_DROP=
    V_PLATFORMS= V_TESTS= V_PUBLISH= V_FILES= V_DEFAULT=no V_FORMAT=

    [ -f "$VARIANT_DIR/$1.conf" ] || {
        echo "error: no such variant: $1" >&2
        echo "       known: $(variant_list | tr '\n' ' ')" >&2
        return 1
    }

    local v
    for v in $(_variant_chain "$1") ; do
        _conf_apply "$VARIANT_DIR/$v.conf" variant || return 1
    done

    [ -n "$V_PLATFORMS" ] || { echo "error: variant $1 declares no platforms" >&2; return 1; }
}

# Platforms reuse the V_* names rather than having P_* of their own, and are loaded into
# a separate call so a caller that wants both holds one at a time. build-rootfs.sh loads
# the variant, saves what it needs, then loads the platform on top — which is exactly the
# resolution order: the platform's omit/drop/keep apply *after* the variant's, and a
# variant cannot override them, because a platform constraint is physical (a container
# has no kernel to run).
platform_load() {  # <name>
    V_NAME=$1
    V_DESCRIPTION= V_PACKAGES= V_OMIT= V_KEEP= V_DROP=
    V_PLATFORMS= V_TESTS= V_PUBLISH= V_FILES= V_DEFAULT=no V_FORMAT=

    [ -f "$PLATFORM_DIR/$1.conf" ] || {
        echo "error: no such platform: $1" >&2
        echo "       known: $(platform_list | tr '\n' ' ')" >&2
        return 1
    }

    _conf_apply "$PLATFORM_DIR/$1.conf" platform || return 1

    [ -n "$V_FORMAT" ] || { echo "error: platform $1 declares no format" >&2; return 1; }
}

variant_list()  { local f; for f in "$VARIANT_DIR"/*.conf;  do [ -e "$f" ] || continue; f=${f##*/}; echo "${f%.conf}"; done; }
platform_list() { local f; for f in "$PLATFORM_DIR"/*.conf; do [ -e "$f" ] || continue; f=${f##*/}; echo "${f%.conf}"; done; }

# The one naming rule, in one place because five scripts and two workflows depend on
# agreeing about it: the default variant keeps the unsuffixed filenames this repository
# had before variants existed — output/rootfs.ext4, output/flfs-oci.tar,
# output/sbom-ext4.json — so docs/release.md, the boot tests and every published tag mean
# what they always meant. Everything else is suffixed with the variant.
image_id() {  # <variant> <platform> -> ext4 | minimal-ext4
    if [ "$1" = "$(default_variant)" ]; then printf '%s' "$2"; else printf '%s-%s' "$1" "$2"; fi
}

default_variant() {
    local v
    for v in $(variant_list); do
        if awk '$1 == "default" && ($2 == "yes" || $2 == "true" || $2 == "1") { found = 1 }
                END { exit !found }' "$VARIANT_DIR/$v.conf"; then
            printf '%s' "$v"
            return 0
        fi
    done
    echo "error: no variant is marked 'default yes', so nothing owns output/rootfs.ext4" >&2
    return 1
}
