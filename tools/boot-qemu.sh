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
# The machine it boots is assembled by test/qemu-lib.sh, which is the same code the four
# boot tests use, and that is the point of sharing it: this is what somebody reaches for
# to debug a boot CI has just failed, so it has to be the *same* guest — same machine
# type, same console device, same kernel command line — and not merely a similar one.
#
# Drop to a raw shell instead of systemd (handy for debugging a broken boot):
#   INIT=/bin/bash ./tools/boot-qemu.sh
#
# Exit the guest with Ctrl-a then x.
set -euo pipefail

cd "$(dirname "$0")/.."
source test/qemu-lib.sh

qemu_setup

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
QEMU_HINT="(run ./tools/fetch-image.sh)"

qemu_preflight
qemu_argv

# Interactive, so the console is this terminal rather than a fifo and a log: no
# qemu_boot, no cleanup trap, nothing to drive. Extra qemu flags are passed through.
exec "$QEMU" "${QEMU_ARGV[@]}" "$@"
