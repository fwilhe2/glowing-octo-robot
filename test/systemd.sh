#!/usr/bin/env bash
# Boot the image with systemd as PID 1 and require that it comes up clean — no failed
# units — so a package that ships a unit it cannot actually run fails CI instead of
# leaving every boot `degraded` for someone to notice by hand.
#
#     ./test/systemd.sh [rootfs.ext4] [bzImage]
#
# Overrides:
#   TIMEOUT    seconds to wait   (default 300 — qemu falls back to TCG in CI, where
#                                there is no KVM, and that is slow)
#   MEM/CPUS   guest size        (default 1024 / 2)
#   LOG        console transcript (default systemd-test.log)
#   LOGIN_USER/LOGIN_PASSWORD  serial console credentials (default root / root)
#
# `systemctl is-system-running` is the whole assertion: it reports `degraded` if and
# only if at least one unit failed, so it covers units nothing else here thinks to look
# at. --wait blocks until startup has actually settled, which is what keeps this from
# racing a unit that is merely slow; the deadline below is what catches one that hangs.
#
# This is deliberately separate from test/boot.sh and test/network.sh rather than folded
# into either: test/boot.sh proves the kernel and the loader work with a raw shell as
# PID 1, test/network.sh proves addressing and DNS, and this proves systemd itself is
# happy. Three failures that mean three different things stay three different tests.
set -euo pipefail

cd "$(dirname "$0")/.."

ROOTFS="${1:-${ROOTFS:-output/rootfs.ext4}}"
KERNEL="${2:-${KERNEL:-rootfs/boot/bzImage}}"
INIT="${INIT:-/usr/lib/systemd/systemd}"
TIMEOUT="${TIMEOUT:-300}"
MEM="${MEM:-1024}"
CPUS="${CPUS:-2}"
LOG="${LOG:-output/systemd-test.log}"
LOGIN_USER="${LOGIN_USER:-root}"
LOGIN_PASSWORD="${LOGIN_PASSWORD:-root}"

# Same trick as test/network.sh: the guest echoes back what is typed at the console
# until `stty -echo` takes effect, so a marker must not appear verbatim in the command
# that produces it. The guest's shell strips the quotes; the patterns below are the
# joined string.
#
# In-guest commands are bash builtins and systemctl only — the image ships no grep, sed
# or awk, so [[ ]] and command substitution stand in for them.
READY="SHELL-IS-UP"
STATE="SYSTEMD-STATE:"
# SYSTEMD_COLORS=0 because the failure diagnostics below are read by whoever is looking
# at a CI log, and systemctl wraps every field of `systemctl --failed` in escapes.
QUIET="stty -echo; PS1=; export SYSTEMD_COLORS=0"
PROBE="echo SHELL-IS'-UP'"
CHECK="echo SYSTEMD'-STATE':\$(systemctl is-system-running --wait)"
DIAGNOSE="systemctl --failed --no-pager --plain; journalctl -p err -b --no-pager -o short"

command -v qemu-system-x86_64 >/dev/null || { echo "error: qemu-system-x86_64 not found" >&2; exit 1; }
[ -f "$KERNEL" ] || { echo "error: missing kernel: $KERNEL" >&2; exit 1; }
[ -f "$ROOTFS" ] || { echo "error: missing rootfs: $ROOTFS" >&2; exit 1; }

accel=()
if [ -w /dev/kvm ]; then
    accel=(-enable-kvm -cpu host)
else
    echo "note: /dev/kvm not available, emulating (slow)"
fi

work=$(mktemp -d)
console="$work/console-in"
mkfifo "$console"
mkdir -p "$(dirname "$LOG")"
: > "$LOG"

qemu-system-x86_64 \
    "${accel[@]}" \
    -m "$MEM" -smp "$CPUS" \
    -kernel "$KERNEL" \
    -drive file="$ROOTFS",format=raw,if=virtio \
    -nic user,model=virtio-net-pci \
    -append "root=/dev/vda rw console=ttyS0 init=$INIT" \
    -nographic \
    -no-reboot \
    < "$console" > "$LOG" 2>&1 &
qemu_pid=$!

cleanup() {
    exec 3>&- 2>/dev/null || true
    kill "$qemu_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT

# Read-write, so opening never blocks on qemu having got as far as its stdin.
exec 3<> "$console"

echo ">> booting $ROOTFS with $KERNEL (init=$INIT), waiting up to ${TIMEOUT}s"

deadline=$((SECONDS + TIMEOUT))
DIED='Kernel panic|Attempted to kill init|Requesting system (poweroff|reboot)'

fail() {
    echo ">> systemd test FAILED: $1" >&2
    # Ask the guest which units failed and why. If it never got as far as a shell this
    # just scrolls past, and the console log is what there is to go on.
    printf '%s\n' "$DIAGNOSE" >&3 2>/dev/null || true
    sleep 5
    echo ">> last 80 lines of the console:" >&2
    tail -80 "$LOG" >&2
    exit 1
}

# Wait for a pattern to show up on the console, keeping an eye on the guest being alive
# and on the overall deadline. Returns 1 on the local timeout so the caller can retry.
await() { # pattern seconds
    local until=$((SECONDS + $2))
    while [ "$SECONDS" -lt "$until" ]; do
        grep -qaE "$1" "$LOG" && return 0
        grep -qaE "$DIED" "$LOG" && fail "the guest died"
        kill -0 "$qemu_pid" 2>/dev/null || fail "qemu exited"
        [ "$SECONDS" -lt "$deadline" ] || fail "timed out waiting for: $1"
        sleep 2
    done
    return 1
}

await 'login:' "$TIMEOUT" || fail "no login prompt"
echo ">> got a login prompt, logging in as $LOGIN_USER"

# agetty reprints the prompt after a failed or mistimed attempt, so the login is worth
# retrying: typing into it while it is still setting the line up loses characters.
until grep -qaF "$READY" "$LOG"; do
    [ "$SECONDS" -lt "$deadline" ] || fail "could not get a shell (login rejected?)"
    printf '%s\n' "$LOGIN_USER" >&3
    await 'Password' 15 || continue
    printf '%s\n' "$LOGIN_PASSWORD" >&3
    sleep 3
    # With the terminal echo off the console log holds the guest's output and nothing
    # else, which keeps a long command line from being redrawn all over the transcript.
    printf '%s\n' "$QUIET" >&3
    printf '%s\n' "$PROBE" >&3
    await "$READY" 10 || true
done

echo ">> logged in, waiting for systemd to finish starting"

printf '%s\n' "$CHECK" >&3
await "$STATE" "$((deadline - SECONDS))" || fail "systemd never reported a final state"

# One line, so the last match is the answer. `running` is the only clean result:
# `degraded` means a unit failed, and `maintenance`/`stopping` mean we should not have
# got a shell at all.
result=$(tr -d '\r' < "$LOG" | sed -n "s/.*${STATE}\\([a-z][a-z-]*\\).*/\\1/p" | tail -1)

case "$result" in
    running)
        echo ">> systemd OK: system is running, no failed units"
        ;;
    degraded)
        fail "system is degraded — at least one unit failed"
        ;;
    *)
        fail "unexpected system state: ${result:-<none>}"
        ;;
esac
