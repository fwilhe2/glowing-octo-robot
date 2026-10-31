#!/usr/bin/env bash
# Boot with system and configuration extensions, from both places a VM gets them, and
# check that they are merged, that what they ship runs, and that one built for another
# level is refused.
#
#     ./test/sysext.sh [rootfs.erofs] [bzImage]
#
# Three toy images, made by tools/build-extension.sh the way any extension is made, and
# put on the /var disk before the first boot (mkfs.ext4 -d) — the path a real one takes,
# with the merge at boot rather than a `systemd-sysext refresh` afterwards:
#
#   flfs-hello   sysext   a unit started by Upholds= from a multi-user.target drop-in,
#                         which reads a file the confext ships into /run; and a second
#                         unit enabled the ordinary way, by a .wants link, which is only
#                         reported (docs/guides/sysext.md: a link merged during sysinit should
#                         miss the boot transaction)
#   flfs-hello   confext  /etc/flfs-hello.conf
#   flfs-wrong   sysext   built for SYSEXT_LEVEL=0, and so never merged
#
# and one pair attached the other way, as read-only disks the VMM hands the guest
# (SYSEXTS in test/qemu-lib.sh), mounted at /run/extensions and /run/confexts:
#
#   flfs-attached  sysext and confext, a file in /usr and one in /etc
#
# Attached images are verified by dm-verity like the root, from tables on the kernel
# command line, so a second, short boot attaches one more:
#
#   flfs-tampered  a sysext with one byte changed after it was sealed — byte 0, which
#                  EROFS never reads, so only verity can be what notices — and which has
#                  to produce device-mapper's corruption report instead of being merged
#
# What is checked in the guest: both hellos and both attached are merged and flfs-wrong
# is not; the
# Upholds= unit ran and saw the confext's file; /etc/machine-id is still PID 1's bind
# mount, which the confext overlay is mounted over; and the boot is `running`.
#
# Needs podman (tools/build-extension.sh assembles in the image container, and the /var
# disk is made under `podman unshare`) and mkfs.ext4.
set -euo pipefail

cd "$(dirname "$0")/.."
source test/qemu-lib.sh

ROOTFS="${1:-${ROOTFS:-output/rootfs.erofs}}"
KERNEL="${2:-${KERNEL:-rootfs/boot/bzImage}}"
INIT="${INIT:-/usr/lib/systemd/systemd}"
TEST_NAME=sysext
LOG="${LOG:-output/sysext-test.log}"

scratch=output/sysext-test   # not $work, which qemu_boot uses for its fifo
toys="output/extensions/flfs-hello.* output/extensions/flfs-wrong.* output/confexts/flfs-hello.*
      output/extensions/flfs-attached.* output/confexts/flfs-attached.* output/extensions/flfs-tampered.*"
# tools/build-extension.sh writes where real extensions go, so the toys are gone again
# when this exits, whichever way (re-armed after qemu_boot, which sets its own trap).
rm -rf "$scratch" $toys
trap 'rm -rf "$scratch" $toys' EXIT
mkdir -p "$scratch"

unit() { # <file> <description> <command>
    cat > "$1" <<EOF
[Unit]
Description=$2

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/bash -c '$3'
EOF
}

# The sysext.
sys="$scratch/hello-sysext/usr/lib/systemd/system"
mkdir -p "$sys/multi-user.target.d" "$sys/multi-user.target.wants"
unit "$sys/flfs-hello.service" "Hello from a system extension" 'cat /etc/flfs-hello.conf > /run/flfs-hello'
printf '[Unit]\nUpholds=flfs-hello.service\n' > "$sys/multi-user.target.d/10-flfs-hello.conf"
unit "$sys/flfs-hello-wants.service" "Hello from a system extension, by .wants" 'touch /run/flfs-hello-wants'
ln -s ../flfs-hello-wants.service "$sys/multi-user.target.wants/flfs-hello-wants.service"
./tools/build-extension.sh sysext flfs-hello "$scratch/hello-sysext"

# The confext.
mkdir -p "$scratch/hello-confext/etc"
echo "hello from a confext" > "$scratch/hello-confext/etc/flfs-hello.conf"
./tools/build-extension.sh confext flfs-hello "$scratch/hello-confext"

# The one with the wrong level.
mkdir -p "$scratch/wrong/usr/share"
echo wrong > "$scratch/wrong/usr/share/flfs-wrong"
LEVEL=0 ./tools/build-extension.sh sysext flfs-wrong "$scratch/wrong"

# The pair the VMM attaches.
mkdir -p "$scratch/attached-sysext/usr/share" "$scratch/attached-confext/etc"
echo attached > "$scratch/attached-sysext/usr/share/flfs-attached"
echo attached > "$scratch/attached-confext/etc/flfs-attached.conf"
./tools/build-extension.sh sysext flfs-attached "$scratch/attached-sysext"
./tools/build-extension.sh confext flfs-attached "$scratch/attached-confext"
SYSEXTS=flfs-attached EXTENSIONS=output

# The one that has been tampered with, for the second boot.
mkdir -p "$scratch/tampered/usr/share"
echo tampered > "$scratch/tampered/usr/share/flfs-tampered"
./tools/build-extension.sh sysext flfs-tampered "$scratch/tampered"
byte=$(od -An -tu1 -N1 output/extensions/flfs-tampered.raw | tr -d ' ')
printf "\\x$(printf '%02x' $(( (byte + 1) % 256 )))" |
    dd of=output/extensions/flfs-tampered.raw bs=1 seek=0 count=1 conv=notrunc status=none

# The /var disk, with the three images where systemd looks for them. x-systemd.makefs
# leaves a disk that already has a filesystem alone, so this is what /var is at boot.
mkdir -p "$scratch/var/lib/extensions" "$scratch/var/lib/confexts"
cp output/extensions/flfs-hello.raw output/extensions/flfs-wrong.raw "$scratch/var/lib/extensions/"
cp output/confexts/flfs-hello.raw "$scratch/var/lib/confexts/"
VAR_DISK="$scratch/var.img"
qemu_seed_var_disk "$VAR_DISK" 1G "$scratch/var"

qemu_setup
qemu_preflight
qemu_boot
trap 'rc=$?; rm -rf "$scratch" $toys; cleanup $rc' EXIT
console_login

OK="SYSEXT-OK"
CHECK="systemctl is-system-running --wait >/dev/null; \
s=\$(systemd-sysext list --no-legend); c=\$(systemd-confext list --no-legend); \
[[ \$s == *flfs-hello* && \$c == *flfs-hello* && \$s == *flfs-attached* && \$c == *flfs-attached* ]] && \
[[ \$(</usr/share/flfs-attached) == attached && \$(</etc/flfs-attached.conf) == attached ]] && \
[[ \$(findmnt -n -o SOURCE /run/extensions/flfs-attached) == /dev/mapper/ext-flfs-attached ]] && \
[[ \$(systemd-sysext status --no-legend) == *flfs-hello* ]] && [ ! -e /usr/share/flfs-wrong ] && \
[[ \$(</run/flfs-hello) == 'hello from a confext' ]] && \
findmnt -rn /etc/machine-id >/dev/null && \
[[ \$(systemctl is-system-running) == running ]] && \
echo \"wants-link unit: \$([ -e /run/flfs-hello-wants ] && echo started || echo not started)\" && \
echo SYSEXT'-OK'"
DIAGNOSE="systemd-sysext status; systemd-confext status; systemd-sysext list; systemctl --no-pager status flfs-hello.service systemd-sysext.service systemd-confext.service; systemctl --failed --no-pager; journalctl --no-pager -b -u systemd-sysext -u systemd-confext -n 40; findmnt /etc /usr /etc/machine-id"

mark=$(console_mark)
console_send "$CHECK"
await "$OK" 120 "$mark" || fail "the extensions were not merged, or what they ship did not run"
grep -a -o 'wants-link unit: [a-z ]*' "$LOG" | tail -1 | sed 's/^/>> /'
echo ">> sysext OK: flfs-hello merged from the /var disk and flfs-attached from read-only disks, the Upholds= unit ran, flfs-wrong (SYSEXT_LEVEL=0) refused"

# The second boot: the tampered image attached and nothing else. The kernel builds its
# verity device from the table before userspace starts, and reading the image through it
# has to fail with device-mapper's report — on the console, where the kernel logs it.
cleanup
trap 'rm -rf "$scratch" $toys' EXIT
LOG="${LOG%.log}-tampered.log"
VAR_DISK= SYSEXTS=flfs-tampered
# The corruption is the point, and the extension's mount-extra= is a mount the boot
# requires, so it ends in emergency mode.
CONSOLE_BAD_EXEMPT='device-mapper: verity|emergency mode|Emergency Shell'
qemu_boot
trap 'rc=$?; rm -rf "$scratch" $toys; cleanup $rc' EXIT
CORRUPT='device-mapper: verity.*(corrupted|verification failed)'
await "$CORRUPT" 180 || fail "a tampered extension was read without dm-verity objecting"
echo ">> sysext OK: a tampered extension is refused by dm-verity, as the root is"
