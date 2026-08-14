#!/usr/bin/env bash
# Boot the image in qemu with nobody at the console and check that userspace actually
# runs, so a package update that produces an unbootable image fails CI instead of
# being discovered the next time someone boots it by hand.
#
#     ./test/boot.sh [rootfs.ext4] [bzImage]
#
# Overrides:
#   INIT      PID 1 to run          (default /bin/bash)
#   PROMPT    regex the shell's prompt matches, i.e. when it is safe to type
#                                   (default bash-[0-9]; change it with INIT)
#   TIMEOUT   seconds to wait       (default 300 — qemu falls back to TCG in CI,
#                                    where there is no KVM, and that is slow)
#   MEM/CPUS  guest size            (default 1024 / 2)
#   LOG       console transcript    (default boot-test.log)
#
# It drives PID 1 over the serial console: once a shell is up it types a command and
# waits for the output to come back. That is a deliberately low bar — it proves the
# kernel mounted the root filesystem, exec'd userspace and that the dynamic loader
# resolved a real binary's libraries, which is exactly what a bad package update
# breaks — and keeping systemd out of it keeps that failure distinguishable from a unit
# that didn't start. test/network.sh is the one that boots systemd for real.
#
# This is the one test that does not log in: PID 1 *is* the shell, so test/qemu-lib.sh's
# console_login has nothing to talk to and the loop below types at the prompt directly.
set -euo pipefail

cd "$(dirname "$0")/.."
source test/qemu-lib.sh

ROOTFS="${1:-${ROOTFS:-boot-image/rootfs.ext4}}"
KERNEL="${2:-${KERNEL:-boot-image/bzImage}}"
INIT="${INIT:-/bin/bash}"
LOG="${LOG:-output/boot-test.log}"
TEST_NAME=boot

# The marker must not appear in the command that produces it: the guest echoes back
# everything typed at the console, and matching our own input would pass every time.
MARKER="BOOT-SMOKE-OK"
COMMAND="uname -srm; echo BOOT-SMOKE'-OK'"

# Nothing may be typed before this appears in the transcript, and that is a correctness
# requirement rather than tidiness. arm64's console is a PL011, and qemu stops reading
# its own stdin the moment that model's receive FIFO fills. The FIFO is only drained
# once the guest opens /dev/console and enables receive interrupts — which is what
# starting a shell on it does — so a command line typed before then sits there unread,
# and qemu never resumes: the console is deaf for the rest of the boot. The image comes
# up perfectly and the test times out anyway, with a prompt as the last thing in the
# log. amd64's 16550 recovers from exactly the same abuse, which is why typing blind
# from t=0 worked for as long as this only ever ran on amd64.
PROMPT="${PROMPT:-bash-[0-9]}"

qemu_setup
qemu_preflight
qemu_boot

status=timeout
typed=

while [ "$SECONDS" -lt "$deadline" ]; do
    if grep -qF "$MARKER" "$LOG"; then
        status=ok
        break
    fi
    if grep -qE "$QEMU_DIED" "$LOG"; then
        status=died
        break
    fi
    if ! kill -0 "$qemu_pid" 2>/dev/null; then
        status=exited
        break
    fi
    # Stay silent until the shell has printed a prompt (see PROMPT above), then retry
    # until it lands: even after the prompt the first line can race the shell finishing
    # its own startup and come back chewed up, and re-running it costs nothing.
    if [ -n "$typed" ] || grep -qE "$PROMPT" "$LOG"; then
        typed=yes
        console_send "$COMMAND"
    fi
    sleep 2
done

# Worth distinguishing: a boot that never got as far as a prompt is a broken image,
# while one that printed a prompt and then ignored everything typed at it is a broken
# console — and the two want to be debugged in completely different places.
if [ "$status" = timeout ] && [ -z "$typed" ]; then
    status="timeout, no shell prompt"
fi

if [ "$status" = ok ]; then
    echo ">> boot OK"
    grep -F -A2 "$MARKER" "$LOG" | sed 's/^/   /' | head -5
    exit 0
fi

fail "$status"
