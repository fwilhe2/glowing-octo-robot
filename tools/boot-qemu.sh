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
#   SSH      0 to boot without the ssh forward and key below   (default 1)
#   SSH_PORT host port forwarded to the guest's 22   (default the first free one from 2222)
#   SSH_DIR  where the ephemeral key and ssh_config go   (default output/ssh)
#
# The guest gets one virtio-net NIC on qemu's user-mode network (10.0.2.15/24, gateway
# and DNS forwarder at 10.0.2.2/10.0.2.3), which systemd-networkd picks up over DHCP.
# It is unprivileged and outbound-only apart from one forward, 127.0.0.1:$SSH_PORT to
# the guest's sshd.
#
# Log in over ssh, without a password, from another terminal:
#
#     ./tools/ssh.sh                  # a root shell
#     ./tools/ssh.sh systemctl status # or a command
#     scp -F output/ssh/config file flfs:/tmp/
#
# That works because every boot gets a fresh ed25519 key pair, generated here into
# $SSH_DIR and deleted when qemu exits, whose public half the guest is handed at boot as
# the systemd credential ssh.authorized_keys.root — the same idea as Vagrant's per-machine
# key and Lima's injected one, with nothing written into the image. test/qemu-lib.sh
# (qemu_ssh_setup) has the details. The key is root's: root's password is refused over
# the network, by key it is not.
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
if [ "${SSH:-1}" = 1 ]; then
    qemu_ssh_setup
    echo ">> ssh: ./tools/ssh.sh  (root@127.0.0.1:$SSH_PORT, key in $SSH_DIR, gone when qemu exits)"
fi
qemu_argv

# Interactive, so the console is this terminal rather than a fifo and a log: no
# qemu_boot, nothing to drive. Extra qemu flags are passed through. Not exec'd, so the
# ephemeral key can be deleted once the guest is gone.
trap '[ -z "${QEMU_SSH_DIR:-}" ] || rm -rf "$QEMU_SSH_DIR"' EXIT
"$QEMU" "${QEMU_ARGV[@]}" "$@"
