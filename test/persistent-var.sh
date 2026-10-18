#!/usr/bin/env bash
# Boot the same VM twice with a disk for /var, and check that what the first boot wrote
# is there in the second — while the root filesystem stays the same read-only image.
#
#     ./test/persistent-var.sh [rootfs.erofs] [bzImage]
#
# The disk is a fresh sparse file each run, so the first boot also proves the part that
# only happens once: systemd-makefs putting ext4 on a blank disk (x-systemd.makefs, from
# the systemd.mount-extra= test/qemu-lib.sh passes). What has to survive, and why each:
#
#   a file in /var/lib    the plain case
#   a podman image        /var/lib/containers, the reason a persistent /var is wanted
#   the journal           Storage=persistent (image/files/etc/systemd/journald.conf.d),
#                         so `journalctl --list-boots` sees the previous boot
#   the machine ID        from <disk>.machine-id on the kernel command line; with the
#                         image's /etc/machine-id empty, every boot would otherwise be a
#                         new machine writing a new journal directory
#
# The default — no disk, /var in RAM — is what every other boot test runs on, so it
# needs no test of its own here.
set -euo pipefail

cd "$(dirname "$0")/.."
source test/qemu-lib.sh

ROOTFS="${1:-${ROOTFS:-output/rootfs.erofs}}"
KERNEL="${2:-${KERNEL:-rootfs/boot/bzImage}}"
INIT="${INIT:-/usr/lib/systemd/systemd}"
TEST_NAME=persistent-var
LOG_BASE="${LOG:-output/persistent-var-test}"

VAR_DISK="$(dirname "$LOG_BASE")/persistent-var-test.img"
rm -f "$VAR_DISK" "$VAR_DISK.machine-id"
machine_id_wanted() { cat "$VAR_DISK.machine-id"; }

FIRST_OK="VAR-FIRST-OK"
SECOND_OK="VAR-SECOND-OK"

ON_DISK="[[ \$(findmnt -rno SOURCE,FSTYPE /var) == '/dev/vdb ext4' ]]"

boot() { # <log suffix>
    LOG="$LOG_BASE-$1.log"
    qemu_setup
    qemu_preflight
    qemu_boot
    console_login
}

# Power off and wait for qemu to go: -no-reboot makes it exit when the guest halts, and
# the second boot must not start until the first has written everything back.
shutdown_guest() {
    console_send "systemctl poweroff"
    local until=$((SECONDS + 120))
    while kill -0 "$qemu_pid" 2>/dev/null; do
        [ "$SECONDS" -lt "$until" ] || fail "the guest did not power off"
        sleep 2
    done
    cleanup
}

boot first
want=$(machine_id_wanted)   # written by qemu_var_disk as the first boot started
echo ">> first boot: /var on a blank disk, machine ID $want"

FIRST="$ON_DISK && [[ \$(</etc/machine-id) == $want ]] && \
cat /proc/sys/kernel/random/boot_id > /var/lib/persistent-var-test && \
tar -C /usr/share/flfs -c sbom.json | podman import - localhost/persisted >/dev/null && \
echo VAR'-FIRST-OK'"
DIAGNOSE="findmnt /var; cat /etc/machine-id; systemctl --no-pager status var.mount systemd-makefs@*; journalctl --no-pager -b -u 'systemd-makefs*' -n 30"

console_send "$FIRST"
await "$FIRST_OK" 180 || fail "first boot: /var is not the disk, the machine ID is wrong, or podman could not store an image"
echo ">> first boot OK: /var is ext4 on /dev/vdb, wrote a file and a podman image"
shutdown_guest

boot second
echo ">> second boot: the same disk"
SECOND="$ON_DISK && [[ \$(</etc/machine-id) == $want ]] && \
first=\$(</var/lib/persistent-var-test) && [[ \$first != \$(</proc/sys/kernel/random/boot_id) ]] && \
podman image exists localhost/persisted && \
journalctl -q -b -1 -n 1 >/dev/null && \
echo VAR'-SECOND-OK'"
DIAGNOSE="findmnt /var; cat /var/lib/persistent-var-test /proc/sys/kernel/random/boot_id; podman images; journalctl --no-pager --list-boots"

console_send "$SECOND"
await "$SECOND_OK" 180 || fail "second boot: the first boot's file, image, journal or machine ID did not survive"
echo ">> second boot OK: the file, the podman image, the previous boot's journal and the machine ID all survived"

shutdown_guest
rm -f "$VAR_DISK" "$VAR_DISK.machine-id"
