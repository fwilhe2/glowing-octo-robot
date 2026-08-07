#!/usr/bin/env bash
# Every package declares a license, and every license is one this image will carry:
#
#     ./test/check-licenses.sh
#
# The declaration is `LICENSE=` in the package's env.sh, as an SPDX expression. The list
# of acceptable identifiers is test/dfsg-licenses.txt, and the bar is the Debian Free
# Software Guidelines — see that file for why.
#
# This is cheap and needs nothing built, which is why it is its own workflow rather than a
# step in the middle of CI: a package whose license is wrong should be answered in seconds,
# on the pull request that adds it, not after forty minutes of compiling.
#
# What it checks is that a declaration exists and is free. What it cannot check is that
# the declaration is *true* — nothing here opens the tarball. That is a packaging step,
# done once against the COPYING the tarball ships, and re-checked when a version bump
# crosses a relicensing.
set -euo pipefail

cd "$(dirname "$0")/.."

ALLOWLIST=test/dfsg-licenses.txt

declare -A allowed
while read -r line; do
    line="${line%%#*}"                       # strip comments
    read -r identifier _ <<<"$line" || true  # and surrounding whitespace
    [ -n "${identifier:-}" ] || continue
    allowed["$identifier"]=1
done < "$ALLOWLIST"

[ "${#allowed[@]}" -gt 0 ] || {
    echo "error: $ALLOWLIST lists no licenses" >&2
    exit 1
}

undeclared=()
rejected=()

for env_file in packages/*/env.sh; do
    pkg=$(basename "$(dirname "$env_file")")

    # shellcheck disable=SC1090
    license=$( PKG="$pkg"; . "$env_file"; printf '%s' "${LICENSE:-}" )

    if [ -z "$license" ]; then
        printf '  %-12s %s\n' "$pkg" "(no LICENSE declared)"
        undeclared+=("$pkg")
        continue
    fi

    # An SPDX expression, so pull the identifiers out of it: parentheses become
    # separators, and the three operators are not identifiers.
    bad=()
    for token in $(printf '%s' "$license" | tr '()' '  '); do
        case "$token" in
            AND|OR|WITH) continue ;;
        esac
        [ -n "${allowed[$token]:-}" ] || bad+=("$token")
    done

    if [ ${#bad[@]} -gt 0 ]; then
        printf '  %-12s %-52s NOT ALLOWED: %s\n' "$pkg" "$license" "${bad[*]}"
        rejected+=("$pkg")
    else
        printf '  %-12s %s\n' "$pkg" "$license"
    fi
done

echo

if [ ${#undeclared[@]} -gt 0 ]; then
    echo "error: no LICENSE in packages/{${undeclared[*]}}/env.sh" >&2
    echo "       Add one, as an SPDX expression describing what the tarball ships:" >&2
    echo "" >&2
    echo "           LICENSE=\"GPL-3.0-or-later\"" >&2
    echo "           LICENSE=\"BSD-3-Clause OR GPL-2.0-only\"      # upstream offers a choice" >&2
    echo "           LICENSE=\"LGPL-2.1-or-later AND GPL-2.0-or-later\"  # library and tools differ" >&2
    echo "" >&2
    echo "       Read it off the tarball's COPYING rather than assuming." >&2
fi

if [ ${#rejected[@]} -gt 0 ]; then
    echo "error: ${#rejected[@]} package(s) declare a license that is not in $ALLOWLIST:" >&2
    echo "       ${rejected[*]}" >&2
    echo "" >&2
    echo "       Either the identifier is misspelled, or this is a license nobody has" >&2
    echo "       decided about yet. The second case is a real decision: the bar is the" >&2
    echo "       Debian Free Software Guidelines, so a license Debian ships in main can" >&2
    echo "       be added to $ALLOWLIST, and one that only exists in non-free means the" >&2
    echo "       package does not belong in this image." >&2
fi

if [ ${#undeclared[@]} -gt 0 ] || [ ${#rejected[@]} -gt 0 ]; then
    exit 1
fi

echo "all ${#allowed[@]} allowed licenses, $(ls -d packages/*/ | wc -l) packages, nothing undeclared or non-free"
