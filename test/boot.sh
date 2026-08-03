#!/usr/bin/env bash
# Boot the image in qemu with nobody at the console and check that userspace actually
# runs, so a package update that produces an unbootable image fails CI instead of
# being discovered the next time someone boots it by hand.
#
#     ./test/boot.sh [rootfs.ext4] [bzImage]
#
# Overrides:
#   INIT      PID 1 to run          (default /bin/bash)
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
set -euo pipefail

cd "$(dirname "$0")/.."

ROOTFS="${1:-${ROOTFS:-boot-image/rootfs.ext4}}"
KERNEL="${2:-${KERNEL:-boot-image/bzImage}}"
INIT="${INIT:-/bin/bash}"
TIMEOUT="${TIMEOUT:-300}"
MEM="${MEM:-1024}"
CPUS="${CPUS:-2}"
LOG="${LOG:-output/boot-test.log}"

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

# The marker must not appear in the command that produces it: the guest echoes back
# everything typed at the console, and matching our own input would pass every time.
MARKER="BOOT-SMOKE-OK"
COMMAND="uname -srm; echo BOOT-SMOKE'-OK'"

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

status=timeout
deadline=$((SECONDS + TIMEOUT))

while [ "$SECONDS" -lt "$deadline" ]; do
    if grep -qF "$MARKER" "$LOG"; then
        status=ok
        break
    fi
    if grep -qE 'Kernel panic|Attempted to kill init|Requesting system (poweroff|reboot)' "$LOG"; then
        status=died
        break
    fi
    if ! kill -0 "$qemu_pid" 2>/dev/null; then
        status=exited
        break
    fi
    # Retried until it lands: there is no prompt to synchronise on that a shell
    # wouldn't also print while still starting up, and re-running it costs nothing.
    printf '%s\n' "$COMMAND" >&3
    sleep 2
done

if [ "$status" = ok ]; then
    echo ">> boot OK"
    grep -F -A2 "$MARKER" "$LOG" | sed 's/^/   /' | head -5
    exit 0
fi

echo ">> boot FAILED ($status); last 40 lines of the console:" >&2
tail -40 "$LOG" >&2
exit 1
