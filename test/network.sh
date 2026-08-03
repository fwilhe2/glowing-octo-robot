#!/usr/bin/env bash
# Boot the image with systemd as PID 1 and check that the network actually works from
# inside the guest, so a change that leaves the image without an address, without DNS
# or without a route fails CI instead of being discovered by hand.
#
#     ./test/network.sh [rootfs.ext4] [bzImage]
#
# Overrides:
#   HOST/PORT  what to resolve and connect to  (default example.com / 80)
#   TIMEOUT    seconds to wait                 (default 300 — qemu falls back to TCG in
#                                              CI, where there is no KVM, and that is slow)
#   MEM/CPUS   guest size                      (default 1024 / 2)
#   LOG        console transcript              (default network-test.log)
#   LOGIN_USER/LOGIN_PASSWORD  serial console credentials (default root / root)
#
# Unlike test/boot.sh this has to run systemd: the addressing is systemd-networkd's job
# and the resolver is systemd-resolved's, so a raw shell as PID 1 would prove nothing.
# That means logging in at the serial getty first, with the credentials the image ships
# in image/files/etc/shadow.
#
# The three checks are layered so that a failure says where it broke: a routable link
# means DHCP answered, `getent hosts` means the systemd-resolved stub that
# /etc/resolv.conf points at answers, and opening a TCP connection means routing and
# the VMM's NAT work. The last two need the machine running this to have internet
# access — with qemu's user-mode networking the guest reaches the outside through it.
set -euo pipefail

cd "$(dirname "$0")/.."

ROOTFS="${1:-${ROOTFS:-output/rootfs.ext4}}"
KERNEL="${2:-${KERNEL:-rootfs/boot/bzImage}}"
INIT="${INIT:-/usr/lib/systemd/systemd}"
HOST="${HOST:-example.com}"
PORT="${PORT:-80}"
TIMEOUT="${TIMEOUT:-300}"
MEM="${MEM:-1024}"
CPUS="${CPUS:-2}"
LOG="${LOG:-output/network-test.log}"
LOGIN_USER="${LOGIN_USER:-root}"
LOGIN_PASSWORD="${LOGIN_PASSWORD:-root}"

# Same trick as test/boot.sh: the guest echoes back everything typed at the console, so
# a marker must not appear in the command that produces it or we would match our own
# input. The guest's shell strips the quotes; the patterns below are the joined string.
#
# The checks use nothing but bash builtins, networkctl and getent: the image ships no
# grep, sed or awk, and bash's [[ ]] and /dev/tcp cover what they would have been for.
READY="SHELL-IS-UP"
MARKER="NET-SMOKE-OK"
QUIET="stty -echo; PS1="
PROBE="echo SHELL-IS'-UP'"
CHECK="[[ \$(networkctl --no-pager) == *routable* ]] \
&& getent hosts $HOST >/dev/null \
&& (exec 3<>/dev/tcp/$HOST/$PORT) \
&& echo NET-SMOKE'-OK'"
DIAGNOSE="networkctl --no-pager status; resolvectl --no-pager status; cat /etc/resolv.conf"

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
    echo ">> network test FAILED: $1" >&2
    # Ask the guest what it thinks its network looks like. If it never got as far as a
    # shell this just scrolls past, and the console log is what there is to go on.
    printf '%s\n' "$DIAGNOSE" >&3 2>/dev/null || true
    sleep 5
    echo ">> last 60 lines of the console:" >&2
    tail -60 "$LOG" >&2
    exit 1
}

# How much console output there is so far, as a byte offset into the log — the caller
# takes one of these before it types something and passes it to await, so that only the
# guest's answer can satisfy the wait. See the login handshake below for why that
# matters.
console_mark() { wc -c < "$LOG"; }

# Wait for a pattern to show up on the console, keeping an eye on the guest being alive
# and on the overall deadline. Returns 1 on the local timeout so the caller can retry.
# With a third argument, output before that offset is ignored.
await() { # pattern seconds [since]
    local until=$((SECONDS + $2)) since="${3:-0}"
    while [ "$SECONDS" -lt "$until" ]; do
        tail -c "+$((since + 1))" "$LOG" | grep -qaE "$1" && return 0
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
#
# The password waits on output typed *after* the username, not on "Password" appearing
# anywhere in the log: systemd's status lines contain "Query the User Interactively for
# a Password" a few seconds into the boot, and matching that types the password into the
# username prompt. test/systemd.sh has the long version.
until grep -qaF "$READY" "$LOG"; do
    [ "$SECONDS" -lt "$deadline" ] || fail "could not get a shell (login rejected?)"
    prompt=$(console_mark)
    printf '%s\n' "$LOGIN_USER" >&3
    await 'Password' 15 "$prompt" || continue
    printf '%s\n' "$LOGIN_PASSWORD" >&3
    sleep 3
    # With the terminal echo off the console log holds the guest's output and nothing
    # else, which keeps a long command line from being redrawn all over the transcript.
    printf '%s\n' "$QUIET" >&3
    printf '%s\n' "$PROBE" >&3
    await "$READY" 10 || true
done

echo ">> logged in, checking the network"

# Retried until it passes: DHCP takes a moment to complete, and re-running the checks
# costs nothing.
until grep -qaF "$MARKER" "$LOG"; do
    [ "$SECONDS" -lt "$deadline" ] || fail "no address, no DNS or no route out (timed out)"
    grep -qaE "$DIED" "$LOG" && fail "the guest died"
    kill -0 "$qemu_pid" 2>/dev/null || fail "qemu exited"
    printf '%s\n' "$CHECK" >&3
    sleep 5
done

echo ">> network OK: link routable, $HOST resolved, TCP connection to $HOST:$PORT accepted"
