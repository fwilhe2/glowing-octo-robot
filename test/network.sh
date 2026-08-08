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
# The checks come in two rounds, layered so that a failure says where it broke.
#
# The first round asks whether the *system* has a network, using nothing the image had to
# grow a package for: a routable link means DHCP answered, `getent hosts` means the
# systemd-resolved stub that /etc/resolv.conf points at answers, and opening a TCP
# connection means routing and the VMM's NAT work.
#
# The second asks whether anyone logged in could *see and use* it, which is what issue
# #77 was about: `ip` reads the address and route back out of the kernel rather than out
# of networkd's opinion of them, `ping` proves an ICMP socket opens, and `curl` proves
# TLS — name resolution, a chain verified against the shipped CA bundle, and a request.
# Splitting them means "the network is broken" and "the tools are broken" cannot be
# mistaken for one another.
#
# Everything past the first check needs the machine running this to have internet access
# — with qemu's user-mode networking the guest reaches the outside through it.
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
# The first round uses nothing but bash builtins, networkctl and getent. That started as
# a constraint — the image had no grep, sed or awk — and is now a choice: bash's [[ ]]
# and /dev/tcp cover what they would have been for, and a console handshake this
# delicate is better off not depending on a package it is not testing. The second round
# is the one place that rule is deliberately broken, because the tools *are* what it is
# testing; it still parses their output with [[ ]] rather than reaching for grep.
READY="SHELL-IS-UP"
MARKER="NET-SMOKE-OK"
TOOLS_MARKER="NET-TOOLS-OK"
QUIET="stty -echo; PS1="
PROBE="echo SHELL-IS'-UP'"
CHECK="[[ \$(networkctl --no-pager) == *routable* ]] \
&& getent hosts $HOST >/dev/null \
&& (exec 3<>/dev/tcp/$HOST/$PORT) \
&& echo NET-SMOKE'-OK'"
# -oneline so the address and its flags land on one line for [[ ]] to match, and -4 so
# the link-local IPv6 address a NIC has whether or not anything configured it cannot
# satisfy this on its own.
#
# ping goes to the loopback address rather than $HOST on purpose: qemu's user-mode
# networking only forwards ICMP when the *host* kernel lets an unprivileged process open
# a datagram ICMP socket, which is a property of the machine running the test and not of
# the image. 127.0.0.1 asks the question this test can answer — that the binary runs and
# gets its socket — and leaves reachability to the TCP and TLS checks either side of it.
#
# curl carries the whole TLS stack on its back: resolving the name, verifying the chain
# against /etc/ssl/certs/ca-certificates.crt, and speaking HTTP over it. -f so an HTTP
# error status is a failure rather than a zero-length body, -sS so only errors print.
TOOLS_CHECK="[[ \$(ip -4 -oneline address show scope global) == *inet* ]] \
&& [[ \$(ip -4 route show default) == default* ]] \
&& ping -c1 -W5 127.0.0.1 >/dev/null \
&& curl -fsS -o /dev/null https://$HOST/ \
&& echo NET-TOOLS'-OK'"
DIAGNOSE="networkctl --no-pager status; resolvectl --no-pager status; cat /etc/resolv.conf
ip -4 address show; ip -4 route show"

# Defaults to the host's own architecture — CI runs this on a matching amd64 or arm64
# runner, so it never has to be told. Override with ARCH=amd64|arm64 to point at the
# other qemu binary and machine type explicitly. Both uname's spelling (x86_64/aarch64)
# and this repo's (amd64/arm64) are accepted.
ARCH="${ARCH:-$(uname -m)}"
case "$ARCH" in
    x86_64|amd64)  ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) echo "error: unsupported architecture: $ARCH (expected amd64 or arm64)" >&2; exit 1 ;;
esac

# amd64's "pc" machine and default cpu need no flags at all; arm64 has no implicit
# machine type, so qemu-system-aarch64 refuses to start without one. ttyS0 is the 8250
# UART kvm_guest.config/vm.config build in on amd64; arm64's virt board exposes a PL011
# instead, at ttyAMA0 — see packages/kernel/build.sh.
if [ "$ARCH" = arm64 ]; then
    QEMU=qemu-system-aarch64
    CONSOLE=ttyAMA0
else
    QEMU=qemu-system-x86_64
    CONSOLE=ttyS0
fi

command -v "$QEMU" >/dev/null || { echo "error: $QEMU not found" >&2; exit 1; }
[ -f "$KERNEL" ] || { echo "error: missing kernel: $KERNEL" >&2; exit 1; }
[ -f "$ROOTFS" ] || { echo "error: missing rootfs: $ROOTFS" >&2; exit 1; }

# Use KVM acceleration when available. On arm64 that means naming the machine type and
# accel together (-machine virt,accel=kvm) rather than as a separate flag, since virt
# isn't optional there the way amd64's implicit pc machine is.
accel=()
machine=()
if [ "$ARCH" = arm64 ]; then
    if [ -w /dev/kvm ]; then
        machine=(-machine virt,accel=kvm -cpu host)
    else
        echo "note: /dev/kvm not available, emulating (slow)"
        machine=(-machine virt -cpu max)
    fi
elif [ -w /dev/kvm ]; then
    accel=(-enable-kvm -cpu host)
else
    echo "note: /dev/kvm not available, emulating (slow)"
fi

work=$(mktemp -d)
console="$work/console-in"
mkfifo "$console"
mkdir -p "$(dirname "$LOG")"
: > "$LOG"

"$QEMU" \
    "${accel[@]}" "${machine[@]}" \
    -m "$MEM" -smp "$CPUS" \
    -kernel "$KERNEL" \
    -drive file="$ROOTFS",format=raw,if=virtio \
    -nic user,model=virtio-net-pci \
    -append "root=/dev/vda rw console=$CONSOLE init=$INIT" \
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
echo ">> checking the tools a person logged in here would reach for"

# Round two. Nothing above needs retrying to reach here, so anything this round is
# waiting for is a TLS handshake or a slow name lookup rather than a lease — but a few
# more attempts cost nothing next to failing a CI run on one dropped packet.
until grep -qaF "$TOOLS_MARKER" "$LOG"; do
    [ "$SECONDS" -lt "$deadline" ] || \
        fail "ip, ping or curl failed (the network itself is up — see the console below)"
    grep -qaE "$DIED" "$LOG" && fail "the guest died"
    kill -0 "$qemu_pid" 2>/dev/null || fail "qemu exited"
    printf '%s\n' "$TOOLS_CHECK" >&3
    sleep 5
done

echo ">> tools OK: ip shows the lease and a default route, ping runs, curl https://$HOST verified"
