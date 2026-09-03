#!/usr/bin/env bash
# How the image size has moved, for every image this build produced, as a job summary:
#
#     ./test/size-history.sh              # this architecture
#     ./test/size-history.sh arm64        # name one
#     RUNS=20 ./test/size-history.sh      # look further back
#
# test/rootfs-size.sh answers "is this image allowed to be this big", which is a question
# about one build against a number somebody wrote down. This answers a different one:
# *which way is it going*, and did this change move it. A ceiling only ever fires once,
# after the growth has already happened and usually some commits after the one that
# caused it; a trend shows the commit that did it, on the run that did it.
#
# The history comes from the rootfs-size-<arch> artifact that the `rootfs` job already
# uploads on every run, so nothing new is stored anywhere and there is no state to keep
# in the repository. The cost is that it only reaches as far back as artifact retention.
#
# This never fails a build. It reports; test/rootfs-size.sh is what enforces. A missing
# gh, an expired artifact or a first run on a new branch all end in a note rather than a
# non-zero exit — a summary that could break CI would be a bad trade for a summary.
set -uo pipefail

cd "$(dirname "$0")/.."

ARCH="${1:-${ARCH:-$(uname -m)}}"
case "$ARCH" in
    x86_64|amd64)  ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) echo "usage: ${0##*/} [amd64|arm64]" >&2; exit 2 ;;
esac

RUNS="${RUNS:-12}"          # how many past builds to plot
BASE_BRANCH="${BASE_BRANCH:-main}"
WORKFLOW="${WORKFLOW:-ci.yml}"

# Whatever this build actually wrote, rather than a fixed pair: with image variants there
# is one report per (variant, platform) — rootfs-size-ext4.txt and rootfs-size-oci.txt
# for the default variant, rootfs-size-minimal-ext4.txt and friends for the rest.
#
# The history side is deliberately tolerant of a name that did not exist yet: `field`
# answers 0 for a missing file and the loops below skip a zero, so a run from before a
# variant was added simply contributes no point to that variant's line rather than
# failing. Which is the same property that made adding a variant cheap in the first place.
FLAVOURS=$( (cd output 2>/dev/null && ls rootfs-size-*.txt 2>/dev/null) |
            sed -e 's/^rootfs-size-//' -e 's/\.txt$//' | sort | tr '\n' ' ')

# stdout always; the job summary as well when there is one. Same shape as the summary()
# in test/rootfs-size.sh — a local run should print the thing CI would show.
out() { printf '%s\n' "$*"; [ -n "${GITHUB_STEP_SUMMARY:-}" ] && printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"; return 0; }

mib() {  # bytes -> "12.3"
    local tenths=$(( ($1 * 10 + 524288) / 1048576 ))
    printf '%d.%d' $(( tenths / 10 )) $(( tenths % 10 ))
}

delta() {  # bytes -> "+1.2" / "-1.2" / "0.0", with a real minus sign for the table
    local d=$1
    if   [ "$d" -gt 0 ]; then printf '+%s' "$(mib "$d")"
    elif [ "$d" -lt 0 ]; then printf '−%s' "$(mib $(( -d )))"
    else printf '0.0'
    fi
}

field() {  # <kind> <file> -> the bytes on that line, or 0
    local kind=$1 file=$2
    [ -f "$file" ] || { echo 0; return; }
    awk -v k="$kind" '$1 == k { print $2; found=1; exit } END { if (!found) print 0 }' "$file"
}

# ▁▂▃▄▅▆▇█ scaled across the series' own min and max, which is the point: absolute size
# is in the numbers beside it, and what the picture is for is the shape. Indexing an awk
# array rather than substr() on the block string, because these are multi-byte and mawk
# counts bytes.
sparkline() {
    awk -v vals="$*" 'BEGIN {
        n = split(vals, a, " ")
        if (n == 0) { print "—"; exit }
        min = max = a[1]
        for (i = 2; i <= n; i++) { if (a[i] < min) min = a[i]; if (a[i] > max) max = a[i] }
        split("▁ ▂ ▃ ▄ ▅ ▆ ▇ █", b, " ")
        for (i = 1; i <= n; i++) {
            idx = (max == min) ? 4 : int((a[i] - min) * 7 / (max - min)) + 1
            printf "%s", b[idx]
        }
        print ""
    }'
}

# ---------------------------------------------------------------------------------
# This build. Without it there is nothing to compare against and no reason to go to the
# network, so it is checked first.
if [ -z "$FLAVOURS" ]; then
    echo "no size reports in output/ — build an image first (image/build-rootfs.sh writes them)" >&2
    exit 0
fi

# ---------------------------------------------------------------------------------
# The history: the same artifact this job uploads, from the last few successful runs on
# the base branch. `--status success` matters — a run that failed before `rootfs` has no
# artifact to fetch, and asking for one is a slow way to find that out.
HIST=$(mktemp -d)
trap 'rm -rf "$HIST"' EXIT
series_ok=0

if ! command -v gh >/dev/null 2>&1; then
    note="no \`gh\` on PATH, so there is no history to compare against."
elif [ -z "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ] && ! gh auth status >/dev/null 2>&1; then
    note="\`gh\` is not authenticated, so there is no history to compare against."
else
    runs=$(gh run list --workflow "$WORKFLOW" --branch "$BASE_BRANCH" --status success \
               --limit $(( RUNS * 2 )) --json databaseId,headSha,createdAt \
               --jq '.[] | "\(.databaseId) \(.headSha[0:7]) \(.createdAt[0:16])"' 2>/dev/null)

    # Newest first out of the API; walk it that way and stop as soon as there are enough,
    # then reverse for display. Artifacts expire oldest-first, so the tail is where the
    # misses are and there is no point pulling the whole list every time.
    n=0
    while read -r id sha date; do
        [ -n "${id:-}" ] || continue
        [ "$n" -ge "$RUNS" ] && break
        [ "$id" = "${GITHUB_RUN_ID:-}" ] && continue
        if gh run download "$id" --name "rootfs-size-$ARCH" --dir "$HIST/$id" >/dev/null 2>&1; then
            printf '%s %s %s\n' "$id" "$sha" "$date" >> "$HIST/index"
            n=$(( n + 1 ))
        fi
    done <<< "$runs"

    if [ "$n" -gt 0 ]; then
        series_ok=1
        tac "$HIST/index" > "$HIST/index.asc"   # oldest first, the direction a graph reads
    else
        note="no size artifacts found on \`$BASE_BRANCH\` — they expire, and a branch that has never run one has none."
    fi
fi

out "## Image size over time — $ARCH"
out ""

if [ "$series_ok" = 0 ]; then
    out "This build:"
    out ""
    out "| image | size |"
    out "| --- | ---: |"
    for f in $FLAVOURS; do
        out "| \`$f\` | $(mib "$(field total "output/rootfs-size-$f.txt")") MiB |"
    done
    out ""
    out "_${note}_"
    exit 0
fi

# ---------------------------------------------------------------------------------
# The headline table: one row per flavour, the shape on the left and the numbers on the
# right. `main` is the most recent build on the base branch — on a pull request that is
# what this change is being judged against; on a push to main it is the commit before.
out "| image | last $(wc -l < "$HIST/index.asc") builds on \`$BASE_BRANCH\` → now | $BASE_BRANCH | this build | Δ |"
out "| --- | --- | ---: | ---: | ---: |"

for f in $FLAVOURS; do
    now=$(field total "output/rootfs-size-$f.txt")
    series=""
    baseline=0
    while read -r id _sha _date; do
        v=$(field total "$HIST/$id/rootfs-size-$f.txt")
        [ "$v" = 0 ] && continue
        series="$series $v"
        baseline=$v
    done < "$HIST/index.asc"

    out "| \`$f\` | \`$(sparkline "$series $now")\` | $(mib "$baseline") | **$(mib "$now")** | $(delta $(( now - baseline ))) |"
done
out ""
out "MiB, apparent size of the assembled tree — the same number \`test/rootfs-size.sh\` holds to \`test/size-budget.txt\`."
out ""

# ---------------------------------------------------------------------------------
# Where it moved, per directory, against the baseline. This is the half that turns "it
# grew" into something actionable: the ceiling in size-budget.txt tells you a number went
# up, and this says which directory did it on which commit.
for f in $FLAVOURS; do
    baseline_id=$(tail -n1 "$HIST/index.asc" | cut -d' ' -f1)
    base_file="$HIST/$baseline_id/rootfs-size-$f.txt"
    [ -f "$base_file" ] || continue

    # Only movements that round to something: a directory that shifted by a few hundred
    # bytes is a different build of the same content, not news, and a table of ±0.0 rows
    # buries the one row that matters. 51200 bytes is half of the 0.1 MiB this prints to.
    #
    # Sorted by how far it moved rather than which way, largest first — the question this
    # table exists to answer is "what did it", and that is the top row either way.
    rows=$(
        awk -v base="$base_file" '
            function abs(x) { return x < 0 ? -x : x }
            BEGIN { while ((getline line < base) > 0) { split(line, p, " "); if (p[1] == "dir") b[p[3]] = p[2] } }
            $1 == "dir" { seen[$3] = 1; d = $2 - b[$3]; if (abs(d) >= 51200) printf "%d %s %d %d\n", abs(d), $3, $2, d }
            END { for (path in b) if (!(path in seen) && b[path] >= 51200) printf "%d %s %d %d\n", b[path], path, 0, -b[path] }
        ' "output/rootfs-size-$f.txt" | sort -k1,1nr | cut -d' ' -f2-
    )
    [ -n "$rows" ] || continue

    out "<details><summary>Where <code>$f</code> changed against \`$BASE_BRANCH\`</summary>"
    out ""
    out "| directory | now | Δ |"
    out "| --- | ---: | ---: |"
    while read -r path now d; do
        out "| \`$path\` | $(mib "$now") | $(delta "$d") |"
    done <<< "$rows"
    out ""
    out "</details>"
    out ""
done

# The run-by-run numbers behind the sparklines, for when the shape raises a question the
# shape cannot answer.
out "<details><summary>Run by run</summary>"
out ""
header="| date | commit"; rule="| --- | ---"
for f in $FLAVOURS; do header="$header | $f"; rule="$rule | ---:"; done
out "$header |"
out "$rule |"
while read -r id sha date; do
    row="| ${date/T/ } | \`$sha\`"
    for f in $FLAVOURS; do row="$row | $(mib "$(field total "$HIST/$id/rootfs-size-$f.txt")")"; done
    out "$row |"
done < "$HIST/index.asc"
here=${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || echo local)}
row="| **this build** | \`${here:0:7}\`"
for f in $FLAVOURS; do row="$row | **$(mib "$(field total "output/rootfs-size-$f.txt")")**"; done
out "$row |"
out ""
out "</details>"
