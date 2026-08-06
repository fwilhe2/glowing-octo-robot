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
# `systemctl is-system-running` is the main assertion: it reports `degraded` if and
# only if at least one unit failed, so it covers units nothing else here thinks to look
# at. --wait blocks until startup has actually settled, which is what keeps this from
# racing a unit that is merely slow; the deadline below is what catches one that hangs.
# Two more ride along on the same shell, because a login over a serial console is the
# expensive part and running one more command on it is free: systemd's Tainted property,
# and flfsfetch, which is the only binary in usr/bin that anything in test/ ever runs
# for its own sake.
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
# In-guest commands are bash builtins and systemctl only. grep, sed and awk are in the
# image now, but [[ ]] and command substitution already cover this, and keeping the
# handshake free of other packages means a failure here means what it says.
READY="SHELL-IS-UP"
STATE="SYSTEMD-STATE:"
TAINT="SYSTEMD-TAINT:"
FETCH="FLFSFETCH-DONE"
# SYSTEMD_COLORS=0 because the failure diagnostics below are read by whoever is looking
# at a CI log, and systemctl wraps every field of `systemctl --failed` in escapes.
QUIET="stty -echo; PS1=; export SYSTEMD_COLORS=0"
PROBE="echo SHELL-IS'-UP'"
CHECK="echo SYSTEMD'-STATE':\$(systemctl is-system-running --wait)"
# --no-color because this transcript is read as text, in a CI log or output/*.log.
FETCH_RUN="flfsfetch --no-color; echo FLFSFETCH'-DONE'"
# The taint string is systemd's own summary of things it found wrong with the system that
# no unit will ever fail over — an unmerged /usr/sbin, a /var/run that is a directory. It
# is a colon-separated word list, empty on a healthy system, so it costs one more command
# and catches a whole class of image-assembly mistakes that otherwise only turn up when
# somebody happens to read `systemctl status` on a booted guest.
#
# Deliberately not `--value`: the property is "Tainted", and `systemctl show -p` prints
# *nothing at all* for a name it does not know, so a typo here would produce an empty
# string and silently pass forever — which is exactly what the first draft of this check
# did. Keeping the "Tainted=" prefix in the output lets it tell "no taint" apart from
# "never asked the right question".
TAINT_CHECK="echo SYSTEMD'-TAINT':[\$(systemctl show -p Tainted)]"
DIAGNOSE="systemctl --failed --no-pager --plain; journalctl -p err -b --no-pager -o short"

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
    echo ">> systemd test FAILED: $1" >&2
    # Ask the guest which units failed and why. If it never got as far as a shell this
    # just scrolls past, and the console log is what there is to go on.
    printf '%s\n' "$DIAGNOSE" >&3 2>/dev/null || true
    sleep 5
    echo ">> last 80 lines of the console:" >&2
    tail -80 "$LOG" >&2
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
# anywhere in the log. systemd's own status lines contain "Query the User Interactively
# for a Password" a few seconds into the boot, so matching the whole log satisfies the
# wait before login has asked anything: the password goes into the username prompt, the
# next command typed becomes the password, and every attempt is rejected with the
# credentials perfectly correct. The same applies to a previous failed attempt's prompt.
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

# Bracketed, so an empty taint string is still something to match on rather than the
# absence of output — which would be indistinguishable from the command never running.
printf '%s\n' "$TAINT_CHECK" >&3
await "$TAINT" 30 || fail "systemd never reported its taint string"

taint=$(tr -d '\r' < "$LOG" | sed -n "s/.*${TAINT}\\[\\([^]]*\\)\\].*/\\1/p" | tail -1)

case "$taint" in
    "Tainted=")
        echo ">> systemd OK: taint string is empty"
        ;;
    "Tainted="*)
        fail "systemd reports the system as tainted: ${taint#Tainted=} (systemd's src/core/taint.c says what each flag means)"
        ;;
    *)
        fail "could not read systemd's Tainted property (got: ${taint:-<nothing>})"
        ;;
esac

# Partly for the pleasure of seeing it in a CI log, and partly because this is the only
# place anything in test/ runs a binary out of usr/bin that is not already on systemd's
# or login's critical path. It rides along on the shell this test already has rather
# than costing a fifth qemu boot, and flfsfetch is a fair canary: it links nothing but
# glibc and reads /etc/os-release, /proc and /sys, so "it printed its own OS name" means
# the loader, the libc and the shipped /etc all did their jobs.
#
# It is a hard failure rather than a nicety. A binary that is in the image and cannot run
# is exactly the class of bug the rest of this directory exists to catch.
mark=$(console_mark)
printf '%s\n' "$FETCH_RUN" >&3
await "$FETCH" 30 "$mark" || fail "flfsfetch did not run (is /usr/bin/flfsfetch in the image?)"

# Everything the guest emitted after the command was typed, minus the end marker itself.
echo ">> flfsfetch says:"
tail -c "+$((mark + 1))" "$LOG" | tr -d '\r' | sed -e "/$FETCH/,\$d" -e 's/^/   /'

# The OS field exists only if /etc/os-release was found and parsed — flfsfetch omits a
# field it cannot fill rather than printing it empty. Matching the field name rather than
# its value keeps this from breaking the day the name in image/files/etc/os-release
# changes.
if ! tail -c "+$((mark + 1))" "$LOG" | grep -qa 'OS: '; then
    fail "flfsfetch ran but printed no OS field — /etc/os-release unreadable?"
fi
echo ">> flfsfetch OK"
