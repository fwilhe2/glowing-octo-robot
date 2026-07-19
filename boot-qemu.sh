#!/usr/bin/env bash
# Boot the fetched rootfs + kernel in QEMU (serial console in this terminal).
#
# Overrides:
#   KERNEL   path to kernel image   (default boot-image/bzImage)
#   ROOTFS   path to ext4 image     (default boot-image/rootfs.ext4)
#   INIT     PID 1 to run           (default /usr/lib/systemd/systemd)
#   MEM      RAM in MB              (default 1024)
#   CPUS     vCPUs                  (default 2)
#
# Drop to a raw shell instead of systemd (handy for debugging a broken boot):
#   INIT=/bin/bash ./boot-qemu.sh
#
# Exit the guest with Ctrl-a then x.
set -euo pipefail

OUT="${OUT:-boot-image}"
KERNEL="${KERNEL:-$OUT/bzImage}"
ROOTFS="${ROOTFS:-$OUT/rootfs.ext4}"
INIT="${INIT:-/usr/lib/systemd/systemd}"
MEM="${MEM:-1024}"
CPUS="${CPUS:-2}"

command -v qemu-system-x86_64 >/dev/null || { echo "error: qemu-system-x86_64 not found" >&2; exit 1; }
[ -f "$KERNEL" ] || { echo "missing kernel: $KERNEL (run ./fetch-image.sh)" >&2; exit 1; }
[ -f "$ROOTFS" ] || { echo "missing rootfs: $ROOTFS (run ./fetch-image.sh)" >&2; exit 1; }

# Use KVM acceleration when available.
accel=()
[ -w /dev/kvm ] && accel=(-enable-kvm -cpu host)

exec qemu-system-x86_64 \
  "${accel[@]}" \
  -m "$MEM" -smp "$CPUS" \
  -kernel "$KERNEL" \
  -drive file="$ROOTFS",format=raw,if=virtio \
  -append "root=/dev/vda rw console=ttyS0 init=$INIT" \
  -nographic \
  -no-reboot \
  "$@"
