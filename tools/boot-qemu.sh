#!/usr/bin/env bash
# Boot the fetched rootfs + kernel in QEMU (serial console in this terminal).
#
# Overrides:
#   ARCH     amd64 or arm64          (default the host's own architecture)
#   OUT      where the image is      (default output/boot-image, or output/boot-image-$ARCH
#                                    if fetch-image.sh was run with a non-default ARCH)
#   KERNEL   path to kernel image   (default $OUT/bzImage)
#   ROOTFS   path to ext4 image     (default $OUT/rootfs.ext4)
#   INIT     PID 1 to run           (default /usr/lib/systemd/systemd)
#   MEM      RAM in MB              (default 1024)
#   CPUS     vCPUs                  (default 2)
#
# The guest gets one virtio-net NIC on qemu's user-mode network (10.0.2.15/24, gateway
# and DNS forwarder at 10.0.2.2/10.0.2.3), which systemd-networkd picks up over DHCP.
# It is unprivileged and outbound-only — pass -nic user,model=virtio-net-pci,hostfwd=...
# of your own if you need to reach a guest port from the host.
#
# Drop to a raw shell instead of systemd (handy for debugging a broken boot):
#   INIT=/bin/bash ./tools/boot-qemu.sh
#
# Exit the guest with Ctrl-a then x.
set -euo pipefail

cd "$(dirname "$0")/.."

# Defaults to the host's own architecture. Override with ARCH=amd64|arm64 to boot the
# other one — under TCG emulation unless this happens to also be that arch's hardware,
# since KVM only accelerates a guest matching the host CPU. Both uname's spelling
# (x86_64/aarch64) and this repo's (amd64/arm64) are accepted.
ARCH="${ARCH:-$(uname -m)}"
case "$ARCH" in
    x86_64|amd64)  ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) echo "error: unsupported architecture: $ARCH (expected amd64 or arm64)" >&2; exit 1 ;;
esac

# fetch-image.sh only appends -$ARCH to its output directory when ARCH is overridden
# away from the host's own, so a plain ./tools/fetch-image.sh followed by a plain
# ./tools/boot-qemu.sh still finds output/boot-image with no suffix on either side.
host_arch=$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')
if [ "$ARCH" = "$host_arch" ]; then
    OUT="${OUT:-output/boot-image}"
else
    OUT="${OUT:-output/boot-image-$ARCH}"
fi
KERNEL="${KERNEL:-$OUT/bzImage}"
ROOTFS="${ROOTFS:-$OUT/rootfs.ext4}"
INIT="${INIT:-/usr/lib/systemd/systemd}"
MEM="${MEM:-1024}"
CPUS="${CPUS:-2}"

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
[ -f "$KERNEL" ] || { echo "missing kernel: $KERNEL (run ./tools/fetch-image.sh)" >&2; exit 1; }
[ -f "$ROOTFS" ] || { echo "missing rootfs: $ROOTFS (run ./tools/fetch-image.sh)" >&2; exit 1; }

# Use KVM acceleration when available. On arm64 that means naming the machine type and
# accel together (-machine virt,accel=kvm) rather than as a separate flag, since virt
# isn't optional there the way amd64's implicit pc machine is.
accel=()
machine=()
if [ "$ARCH" = arm64 ]; then
    if [ -w /dev/kvm ]; then
        machine=(-machine virt,accel=kvm -cpu host)
    else
        machine=(-machine virt -cpu max)
    fi
elif [ -w /dev/kvm ]; then
    accel=(-enable-kvm -cpu host)
fi

exec "$QEMU" \
  "${accel[@]}" "${machine[@]}" \
  -m "$MEM" -smp "$CPUS" \
  -kernel "$KERNEL" \
  -drive file="$ROOTFS",format=raw,if=virtio \
  -nic user,model=virtio-net-pci \
  -append "root=/dev/vda rw console=$CONSOLE init=$INIT" \
  -nographic \
  -no-reboot \
  "$@"
