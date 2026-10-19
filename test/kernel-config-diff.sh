#!/usr/bin/env bash
# What a kernel build changed about the kernel, as a list a person can read:
#
#     ./test/kernel-config-diff.sh <old .config> <new .config> [<new kernel source>]
#
# Prints nothing and exits 0 when the two agree. Never fails on a difference — this is a
# report, not a gate; packages/kernel/build.sh is the gate, for what the fragments ask
# for. What it cannot see is everything the fragments do *not* name: a new `default y`
# driver, or one added to defconfig, is built in by a kernel bump with nothing here
# saying so. CI's kernel job runs this against the kernel main last built and posts the
# result on the pull request, so following the latest stable kernel stays automatic but
# not blind — a hardware driver that slipped in is cleared in vm.config, in the bump's
# own pull request.
#
# With the kernel source, the report is split, using the new tree's Kconfig files:
#   - options: symbols with a prompt, which is to say somebody's choice — the part to read
#   - derived: prompt-less symbols (ARCH_HAS_*, HAVE_*, library helpers), counted only
# and symbols whose value Kconfig computes from the toolchain are dropped altogether —
# `$(cc-option …)`, the compiler and pahole versions, and the prompt-less symbols that
# depend on those. A Debian snapshot bump moves them with nothing about the kernel
# having changed, and a report that changes every time teaches people not to read it.
# Without the source, every symbol is listed as an option.
set -euo pipefail

[ $# -ge 2 ] && [ $# -le 3 ] || {
    echo "usage: $0 <old .config> <new .config> [<new kernel source>]" >&2; exit 2; }
OLD=$1 NEW=$2 SRC=${3:-}

# "symbol prompted toolchain", for every symbol any Kconfig in the tree defines. One pass
# reads each Kconfig entry into "symbol has-prompt uses-$( referenced-symbols…"; the second
# takes the prompt-less symbols with a `$(` in their defaults or dependencies and closes
# over the prompt-less symbols that depend on those — CC_HAS_COUNTED_BY is
# `default y if GCC_VERSION >= …`, with no `$(` of its own. A symbol with a prompt is never
# a toolchain symbol: whatever moved it, its changing is worth seeing.
classify() {
    find "$SRC" -name 'Kconfig*' -not -path '*/Documentation/*' -print0 \
    | xargs -0 awk '
        function flush() { if (sym != "") print sym, prompt, dollar, refs; sym = "" }
        /^[[:space:]]*(menu)?config[[:space:]]+[A-Z0-9_]+[[:space:]]*$/ {
            flush(); sym = $2; prompt = 0; dollar = 0; refs = ""; next }
        /^[a-z]/ { flush(); next }
        sym == "" { next }
        /^[[:space:]]+(bool|tristate|string|int|hex|prompt)[[:space:]]+"/ { prompt = 1 }
        /^[[:space:]]+(def_bool|def_tristate|def_int|def_hex|def_string|default|depends[[:space:]]+on)[[:space:]]/ {
            if ($0 ~ /\$\(/) dollar = 1
            line = $0; sub(/^[[:space:]]+[a-z_]+([[:space:]]+on)?/, "", line)
            while (match(line, /[A-Z][A-Z0-9_]+/)) {
                refs = refs " " substr(line, RSTART, RLENGTH); line = substr(line, RSTART + RLENGTH) }
        }
        END { flush() }' \
    | awk '
        { known[$1] = 1
          if ($2) prompted[$1] = 1
          if ($3) seed[$1] = 1
          for (i = 4; i <= NF; i++) ref[$1] = ref[$1] " " $i }
        END {
            for (s in seed) if (!(s in prompted)) tc[s] = 1
            do {
                grew = 0
                for (s in ref) {
                    if ((s in tc) || (s in prompted)) continue
                    n = split(ref[s], r, " ")
                    for (i = 1; i <= n; i++) if (r[i] in tc) { tc[s] = 1; grew = 1; break }
                }
            } while (grew)
            for (s in known) print "CONFIG_" s, ((s in prompted) ? 1 : 0), ((s in tc) ? 1 : 0)
        }'
}

# Every symbol that is set, as NAME=value. "is not set" lines are not values: a symbol
# going from =y to unset shows up as its =y line disappearing.
settings() { grep -E '^CONFIG_[A-Z0-9_]+=' "$1" | LC_ALL=C sort; }

# "<sign> NAME=value" for each line in one config and not the other. diff exits 1 on a
# difference, which is the expected case, so the pipeline's status is not the answer.
changes=$({ LC_ALL=C diff <(settings "$OLD") <(settings "$NEW") || true; } \
    | sed -n -e 's/^< /- /p' -e 's/^> /+ /p')
[ -n "$changes" ] || exit 0

# A symbol the new tree does not define at all (removed or renamed by the release) is
# kept as an option: that is precisely the sort of change worth reading. The classes go
# in as a file, not -v: there are some twenty thousand symbols, over ARG_MAX.
awk '
    FILENAME == ARGV[1] { prompted[$1] = $2; tc[$1] = $3; next }
    {
        sign = substr($0, 1, 1); setting = substr($0, 3); name = setting; sub(/=.*/, "", name)
        if (tc[name] == 1) { toolchain++; next }
        if ((name in prompted) && prompted[name] == 0) { derived[sign]++; next }
        print sign " " setting
    }
    END {
        if (derived["+"] + derived["-"] > 0)
            printf "# and %d derived (prompt-less) settings added, %d removed\n", derived["+"], derived["-"]
        if (toolchain > 0)
            printf "# and %d toolchain-derived settings changed, not shown\n", toolchain
    }' <(if [ -n "$SRC" ]; then classify; fi) - <<< "$changes"
