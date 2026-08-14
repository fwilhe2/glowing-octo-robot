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
# happy. Three failures that mean three different things stay three different tests —
# what they share is the plumbing, which is test/qemu-lib.sh.
set -euo pipefail

cd "$(dirname "$0")/.."
source test/qemu-lib.sh

ROOTFS="${1:-${ROOTFS:-output/rootfs.ext4}}"
KERNEL="${2:-${KERNEL:-rootfs/boot/bzImage}}"
INIT="${INIT:-/usr/lib/systemd/systemd}"
LOG="${LOG:-output/systemd-test.log}"
TEST_NAME=systemd

# Same trick as the READY marker in test/qemu-lib.sh: the guest echoes back what is typed
# at the console until `stty -echo` takes effect, so a marker must not appear verbatim in
# the command that produces it. The guest's shell strips the quotes; the patterns below
# are the joined string.
#
# In-guest commands are bash builtins and systemctl only. grep, sed and awk are in the
# image now, but [[ ]] and command substitution already cover this, and keeping the
# handshake free of other packages means a failure here means what it says.
STATE="SYSTEMD-STATE:"
TAINT="SYSTEMD-TAINT:"
FETCH="FLFSFETCH-DONE"
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

qemu_setup
qemu_preflight
qemu_boot
console_login

echo ">> logged in, waiting for systemd to finish starting"

console_send "$CHECK"
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
console_send "$TAINT_CHECK"
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
console_send "$FETCH_RUN"
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
