#!/usr/bin/env bash
# Boot the image on the shapes of machine the kernel is built for besides qemu's own:
#
#     ./test/vmm.sh [rootfs.erofs] [kernel] [microvm|vz ...]   # default: both
#
# packages/kernel/build.sh (guest.config) builds in what Firecracker and Apple's
# Virtualization.framework give a guest, and nothing else here would notice if it went:
# every other test boots qemu's PCI machine, where virtio-pci and a UART are enough. qemu
# cannot be either VMM, but it can give a guest the same devices — test/qemu-lib.sh's
# QEMU_PROFILE — and the devices are what the kernel sees.
#
#   microvm  Firecracker. No PCI device at all: disk, network and entropy are virtio over
#            MMIO, and on amd64 they are announced the way Firecracker announces them, as
#            virtio_mmio.device= arguments on the kernel command line. The kernel is an
#            uncompressed vmlinux booted through its PVH entry point, which is what
#            Firecracker loads on x86 — extracted from the bzImage this repository ships,
#            so the check is on the artifact rather than on a build tree. arm64's Image is
#            already uncompressed, and is what Firecracker loads there.
#   vz       Virtualization.framework. The console is a virtio console (hvc0) with no UART
#            behind it, a host directory is a virtiofs mount, and the host reaches the guest
#            over vsock — here by logging in with ssh through it, as vfkit-style tools do,
#            to sshd's vsock listener that systemd-ssh-generator sets up on its own when a
#            guest has a vsock device. virtiofs needs virtiofsd on the host and vsock needs
#            /dev/vhost-vsock; each part is skipped, with a note, where they are missing.
#
# Both rounds boot systemd for real and log in, and both have to reach `running`: a
# kernel that boots but whose console, entropy or disk only half works shows up as a
# failed unit before it shows up anywhere else.
set -euo pipefail

cd "$(dirname "$0")/.."
source test/qemu-lib.sh

ROOTFS="${1:-${ROOTFS:-output/rootfs.erofs}}"
BZIMAGE="${2:-${KERNEL:-rootfs/boot/bzImage}}"
shift $(($# < 2 ? $# : 2))
PROFILES=("$@")
[ ${#PROFILES[@]} -gt 0 ] || PROFILES=(microvm vz)
INIT="${INIT:-/usr/lib/systemd/systemd}"
DIAGNOSE="systemctl --failed --no-pager --plain; journalctl -p err -b --no-pager -o short"

STATE="VMM-STATE:"
CHECK="echo VMM'-STATE':\$(systemctl is-system-running --wait)"

# The uncompressed kernel inside a bzImage: the payload is the first gzip stream after
# the setup code (packages/kernel/build.sh leaves the compression at defconfig's gzip),
# and gzip stops at the end of it, ignoring the trailer the bzImage carries after.
extract_vmlinux() { # bzImage out
    local off
    off=$(grep -abo $'\x1f\x8b\x08' "$1" | head -1 | cut -d: -f1)
    [ -n "$off" ] || { echo "error: no gzip payload in $1" >&2; return 1; }
    tail -c "+$((off + 1))" "$1" | gzip -dc 2>/dev/null > "$2" || true
    [ "$(head -c 4 "$2")" = $'\x7fELF' ] || { echo "error: $1 did not unpack to an ELF" >&2; return 1; }
}

# One shell command, one marked answer. The marker is assembled by the guest's shell, so
# the echo of what was typed cannot satisfy the wait.
ask() { # name command
    local mark
    mark=$(console_mark)
    console_send "echo VMM-$1'-BEGIN'; $2; echo VMM-$1'-END'"
    await "VMM-$1-END" 60 "$mark" || fail "no answer to: $2"
    tail -c "+$((mark + 1))" "$LOG" | tr -d '\r' | sed -n "/VMM-$1-BEGIN/,/VMM-$1-END/p" | sed '1d;$d'
}

boot_and_check_running() {
    qemu_setup
    qemu_preflight
    qemu_boot
    console_login
    # Kernel messages go to the same console the answers are read from; past this point
    # only a panic (KERN_EMERG) should get through.
    console_send "dmesg -n 1"
    console_send "$CHECK"
    await "$STATE" "$((deadline - SECONDS))" || fail "systemd never reported a final state"
    local result
    result=$(tr -d '\r' < "$LOG" | sed -n "s/.*${STATE}\\([a-z][a-z-]*\\).*/\\1/p" | tail -1)
    [ "$result" = running ] || fail "system is ${result:-in no state at all}, not running"
    echo ">> $PROFILE: system is running"
}

# Which virtio drivers bound to a device: the proof a device was found, not just offered.
# The trailing echo ends the line, so the names are not on the line with ask's end marker.
bound() { ask DRIVERS 'for d in /sys/bus/virtio/devices/*/driver; do basename "$(readlink "$d")"; done | sort -u | tr "\n" " "; echo'; }
expect_driver() { # drivers name
    [[ " $1 " == *" $2 "* ]] || fail "no virtio device bound to $2 (bound: $1)"
}

round_microvm() {
    TEST_NAME=vmm-microvm LOG=output/vmm-microvm-test.log QEMU_PROFILE=microvm
    KERNEL=$BZIMAGE
    if [ "$(normalize_arch "${ARCH:-}")" = amd64 ]; then
        KERNEL=output/vmlinux
        extract_vmlinux "$BZIMAGE" "$KERNEL"
        readelf -n "$KERNEL" | grep -q 'Xen' ||
            { echo "error: $KERNEL has no PVH entry note; Firecracker cannot boot it" >&2; exit 1; }
    fi
    boot_and_check_running

    local pci drivers cmdline
    pci=$(ask PCI 'ls /sys/bus/pci/devices 2>/dev/null | wc -l')
    drivers=$(bound)
    echo ">> microvm: virtio drivers bound: $drivers"
    expect_driver "$drivers" virtio_blk
    expect_driver "$drivers" virtio_net
    expect_driver "$drivers" virtio_rng
    if [ "$PROFILE" = microvm ] && [ "$(normalize_arch "${ARCH:-}")" = amd64 ]; then
        [ "$pci" -eq 0 ] || fail "the microvm guest has $pci PCI devices, expected none"
        cmdline=$(ask CMDLINE 'grep -o "virtio_mmio.device=[^ ]*" /proc/cmdline | wc -l')
        [ "$cmdline" -ge 2 ] || fail "devices were not announced on the command line ($cmdline)"
        echo ">> microvm: no PCI, $cmdline virtio-mmio devices from the command line, PVH boot"
    fi
    cleanup
    trap - EXIT
}

round_vz() {
    TEST_NAME=vmm-vz LOG=output/vmm-vz-test.log QEMU_PROFILE=vz KERNEL=$BZIMAGE
    local share token vfsd_pid= drivers
    share=$(mktemp -d)
    token=$(od -An -tx1 -N8 /dev/urandom | tr -d ' \n')
    echo "$token" > "$share/token"

    VIRTIOFS_SOCKET= VSOCK_CID=
    local virtiofsd
    virtiofsd=$(command -v virtiofsd || ls /usr/libexec/virtiofsd /usr/lib/qemu/virtiofsd 2>/dev/null | head -1 || true)
    if [ -n "$virtiofsd" ]; then
        VIRTIOFS_SOCKET="$share.sock"
        "$virtiofsd" --socket-path="$VIRTIOFS_SOCKET" --shared-dir="$share" --sandbox=none \
            --cache=never >/dev/null 2>&1 &
        vfsd_pid=$!
        for _ in $(seq 50); do [ -S "$VIRTIOFS_SOCKET" ] && break; sleep 0.1; done
        [ -S "$VIRTIOFS_SOCKET" ] || { echo "error: virtiofsd did not start" >&2; exit 1; }
    else
        echo "note: no virtiofsd on this host, skipping the virtiofs check"
    fi
    if [ -w /dev/vhost-vsock ] && command -v socat >/dev/null; then
        VSOCK_CID=$((1000 + RANDOM % 30000))
        qemu_ssh_setup
    else
        echo "note: no /dev/vhost-vsock or socat on this host, skipping the vsock check"
    fi

    boot_and_check_running
    drivers=$(bound)
    echo ">> vz: virtio drivers bound: $drivers"
    expect_driver "$drivers" virtio_console
    expect_driver "$drivers" virtio_rng
    expect_driver "$drivers" virtio_balloon
    [ "$(ask TTY 'tty')" = /dev/hvc0 ] || fail "the login is not on hvc0"

    if [ -n "$VIRTIOFS_SOCKET" ]; then
        expect_driver "$drivers" virtiofs
        local got
        # A line of the answer, not all of it: the kernel logs to the same console, and
        # virtiofsd's reply to the unmount's FUSE_DESTROY draws a harmless "response too
        # short" from it that can land in the middle.
        got=$(ask VIRTIOFS 'mount -t virtiofs share /mnt && cat /mnt/token; umount /mnt')
        grep -qx "$token" <<<"$got" || fail "read '$got' through virtiofs, the host wrote '$token'"
        echo ">> vz: virtiofs mount reads what the host wrote"
    fi
    if [ -n "$VSOCK_CID" ]; then
        expect_driver "$drivers" vmw_vsock_virtio_transport
        local id
        id=$(timeout 60 ssh -F "$SSH_DIR/config" \
                 -o ProxyCommand="socat - VSOCK-CONNECT:$VSOCK_CID:22" flfs \
                 cat /proc/sys/kernel/random/boot_id) || fail "ssh over vsock (cid $VSOCK_CID) failed"
        [ "$id" = "$(ask BOOTID 'cat /proc/sys/kernel/random/boot_id')" ] ||
            fail "ssh over vsock reached a different machine ($id)"
        echo ">> vz: ssh over vsock reaches the guest"
    fi
    cleanup
    trap - EXIT
    [ -z "$vfsd_pid" ] || kill "$vfsd_pid" 2>/dev/null || true
    rm -rf "$share" "${VIRTIOFS_SOCKET:-}" "${VIRTIOFS_SOCKET:+$VIRTIOFS_SOCKET.pid}"
}

for p in "${PROFILES[@]}"; do
    case "$p" in
        microvm) round_microvm ;;
        vz)      round_vz ;;
        *) echo "error: unknown profile $p (microvm, vz)" >&2; exit 2 ;;
    esac
done
echo ">> vmm OK: ${PROFILES[*]}"
